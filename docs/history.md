# HIVE — geçmiş ve kararlar

Güncel durum: [`README.md`](../README.md). Bu sayfa sadece eklenerek büyür; eski kayıtlar düzeltilmez,
yanlış çıkan bir sonuç yeni bir kayıtla düzeltilir.

## 2026-09-25 — ilk EKS deploy'u
- 13:14 UTC `deploy.sh` ile ilk imaj `hive:20260925-131428` (arm64) push edildi; 2 pod Running.
- 13:17:51 UTC ALB trafik almaya başladı: `/health` 200, `/api/stock` `[]` (RDS boş, beklenen).
- Terraform state bir takım üyesinin makinesinde olduğundan `deploy.sh`'a ortam değişkeniyle değer verme eklendi.

## 2026-09-25 — kararlar
- **Altyapı:** düz Terraform (`deploy/terraform`) kabul edildi; alternatif Terragrunt katmanlı yapı
  (S3 state, sadece Actions'tan apply, GitOps) hazırlanmıştı, çalışır durumdaki kurulum lehine bırakıldı.
- **RDS tek AZ:** maliyet ve kurulum süresi için bilinçli tercih. Sonraki adım Multi-AZ (kesintisiz geçilebilir).
- **`chem-` öneki:** kaynak adlarında uygulanmadı; yeniden adlandırma kaynakları yeniden oluşturacağı için atlandı.
- **Trivy bulguları** (public EKS endpoint, node egress) `.trivyignore`'a gerekçesiyle eklendi, sona bırakıldı.
- **ALB internet-facing:** puanlama botu dışarıdan eriştiği için zorunlu.

## 2026-09-25 — göç güvenliği düzeltmeleri
- `deploy.sh` her çalıştığında `HIVE_API_TOKEN` üretiyordu. Bot `POST /api/stock`'u token olmadan attığı
  için trafik geçince her yazma 401 alacaktı. Token opsiyonel yapıldı.
- Uygulama boş DB'de 18 örnek ürün yazıyordu; göç edilecek gerçek veriyle id çakışması yaratırdı.
  `HIVE_SEED_SAMPLE_DATA=true` olmadıkça yazılmıyor.
- Açılışta DB 15 sn içinde yoksa uygulama kapanıyordu; RDS failover'ında crash-loop riski. 2 dk'ya çıkarıldı.

## 2026-09-25 — eski ortam bulguları (assessment)
- Saatlik yedek 2026-09-24'ten beri başarısız (`backup.sh` eski şifre kullanıyor); son sağlam yedek 2026-03-20.
- PostgreSQL ve uygulama portu internete açık; DB şifresi unit dosyası, script'ler ve kodda düz metin.
- `bot-chem-N` notlu hareketler puanlama botundan geliyor (saniyede bir, `/health` + `POST /api/stock`).
