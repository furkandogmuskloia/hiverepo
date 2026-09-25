# Yedekleme ve felaket kurtarma (DR)

## Son durum — 2026-09-25 14:00 UTC

| Ortam | Yedek | RPO (en fazla kaybedilecek veri) | RTO (geri dönüş süresi) | Kanıt | Durum |
|---|---|---|---|---|---|
| **Eski sunucu** (PostgreSQL 15, tek makine) | Saatlik `backup.sh` **2026-03-24'ten beri başarısız**: 4.417 ardışık hata, DB şifresi değişmiş ama script güncellenmemiş; hata günlüğe değil cron mailine gidiyor, bugün de 20 baytlık boş dosya üretiyor. Son sağlam dump'ın dosya zamanı 2026-03-24 21:46 (adı 20260320) | **~6 ay** | bilinmiyor, hiç denenmemiş | — | ❌ Göç bitene kadar verinin tek kopyası |
| Eski sunucu — bugünkü kurtarma dump'ı | 13:53 UTC, dışarıdan alınan tutarlı dump, laptop'ta | 13:53'ten sonrası | **29 sn** (restore) | Aşağıda: sayılar birebir | ✅ Alındı, restore edildi |
| **RDS `hive-pg`** (PostgreSQL 16) | Otomatik yedek + zaman noktasına geri dönüş, **Multi-AZ** (senkron yedek makine) | AZ arızası: **~0**; mantıksal hata/silme: **~5 dk** (PITR) | AZ arızası: 1–2 dk otomatik failover; PITR: ~15–30 dk | `LatestRestorableTime` canlı | ✅ Multi-AZ açık · saklama **1 gün → 7 gün** PR'da |
| RDS silme koruması | `deletion_protection`, silmede final snapshot | — | — | — | PR'da (bugün kapalı) |

## Kanıt: eski DB'nin dump + restore testi (2026-09-25)

| Adım | Sonuç |
|---|---|
| Kaynak sayıları, dump anında (13:53:30 UTC) | ürün **18**, hareket **408.067** (max id 408.067), rapor **220**, toplam stok **9.710** |
| Dump | `pg_dump -Fc` (tek tutarlı anlık görüntü; yazmaları bloklamaz), 6,6 MB, sha256 `707e6dae…2c26551` |
| Restore | temiz bir PostgreSQL 15 container'ına `pg_restore --exit-on-error` → exit 0, **29 sn** |
| Restore sonrası sayılar | 18 / 408.067 / 408.067 / 220 / 9.710 → **kaynakla birebir aynı** |

Sunucuya hiçbir şey yazılmadı; dump SSH üzerinden doğrudan dışarı aktarıldı (sunucunun AWS erişimi yok).

## Runbook

### Eski DB'nin dump'ı (göç bitene kadar, ~15 dk'da bir önerilir)

```bash
TS=$(date -u +%Y%m%dT%H%MZ)
ssh -i <anahtar> ec2-user@<eski-sunucu> \
  'sudo -u postgres pg_dump -d hive -Fc -Z6 --no-owner --no-privileges' \
  > hive-legacy-$TS.dump
shasum -a 256 hive-legacy-$TS.dump
```

Beklenen: birkaç MB'lık dosya; `pg_restore --list hive-legacy-$TS.dump | grep -c "TABLE DATA"` → `3`.

### Restore testi (salt okunur, lokal)

```bash
docker run -d --rm --name restore-test \
  -e POSTGRES_PASSWORD=x -e POSTGRES_DB=hive postgres:15-alpine
docker exec -i restore-test pg_restore -U postgres -d hive \
  --no-owner --no-privileges --exit-on-error < hive-legacy-<TS>.dump
docker exec restore-test psql -U postgres -d hive -XAtc \
  "select (select count(*) from products),(select count(*) from movements),(select max(id) from movements)"
docker rm -f restore-test
```

Beklenen: exit 0 ve sayılar dump anındaki kaynak sayılarıyla aynı.

### RDS: zaman noktasına geri dönüş (yeni instance'a; mevcut DB'ye dokunmaz)

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier hive-pg \
  --target-db-instance-identifier hive-pg-restore-<ts> \
  --use-latest-restorable-time \
  --db-subnet-group-name <hive-pg'nin subnet group'u> \
  --no-multi-az
```

Beklenen: yeni instance ~15–30 dk içinde `available`; sayılar karşılaştırılır, sonra silinir.

## Maliyet (aylık, yaklaşık)

| Kalem | Maliyet |
|---|---|
| RDS Multi-AZ (db.t4g.micro) | ~+13 USD (tek AZ'ye göre) |
| 7 gün otomatik yedek | ~0 (veritabanı boyutu kadar yedek alanı ücretsiz; DB ~41 MB) |
| Alarmlar + bildirim | ~1 USD |
| (sonraki adım) AWS Backup + başka bölgeye kopya | ~1–3 USD |

## Sonraki adımlar

- Eski sunucudaki `backup.sh` düzeltilir veya kapatılır (göçten sonra eski sunucu emekliye ayrılır).
- RDS için AWS Backup planı + başka bölgeye kopya + değiştirilemez kasa (uyum gereksinimi).
- Üç ayda bir restore tatbikatı; sonucu bu sayfaya tarihli eklenir.
