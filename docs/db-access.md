# RDS erişimi, dump ve veri doğrulama

RDS (`hive-pg`) internete kapalı. Erişim, SSM Session Manager ile bastion üzerinden **port-forward**:
SSH yok, public IP yok, açık port yok; her oturum CloudTrail'e yazılır. Bastion: `deploy/terraform/bastion.tf`.

## Önkoşullar

- AWS kimliği: `export AWS_PROFILE=<profil>`; `aws sts get-caller-identity` hesabı göstermeli.
- Session Manager eklentisi: `brew install --cask session-manager-plugin`, sonra `session-manager-plugin --version`.
- PostgreSQL 16 istemcisi: `pg_dump --version` → `16.x` (sunucu 16; eski bir pg_dump reddeder).

## 1. Port-forward aç (ayrı bir terminalde açık kalır)

```bash
terraform -chdir=deploy/terraform output -raw db_port_forward_command
```

Çıkan komutu çalıştırın. Beklenen: `Port 5433 opened for sessionId ...` ve `Waiting for connections...`.
State'e erişim yoksa:

```bash
BASTION=$(aws ec2 describe-instances --region eu-central-1 \
  --filters "Name=tag:Name,Values=hive-bastion" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
DB_HOST=$(aws rds describe-db-instances --region eu-central-1 \
  --db-instance-identifier hive-pg --query 'DBInstances[0].Endpoint.Address' --output text)
aws ssm start-session --region eu-central-1 --target "$BASTION" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$DB_HOST,portNumber=5432,localPortNumber=5433"
```

## 2. Şifreyi al (ekrana basılmaz, değişkene)

```bash
SECRET_ARN=$(aws rds describe-db-instances --region eu-central-1 \
  --db-instance-identifier hive-pg --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
export PGPASSWORD=$(aws secretsmanager get-secret-value --region eu-central-1 \
  --secret-id "$SECRET_ARN" --query SecretString --output text \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
export PGHOST=localhost PGPORT=5433 PGUSER=hive PGDATABASE=hive PGSSLMODE=require
psql -XAtc 'select version()'
```

Beklenen: `PostgreSQL 16.x on aarch64-unknown-linux-gnu...`. `sslmode=require` şart (RDS `rds.force_ssl=1`).
Not: host `localhost` olduğu için sertifika adı doğrulanamaz; `verify-full` burada çalışmaz.

## 3. Dump al (salt okunur; yazmaları bloklamaz)

```bash
TS=$(date -u +%Y%m%dT%H%MZ)
psql -XAtc "select now() at time zone 'utc', (select count(*) from products), \
  (select count(*) from movements), (select max(id) from movements), \
  (select count(*) from daily_reports), (select sum(quantity) from products)" \
  | tee hive-rds-$TS.counts
pg_dump -Fc -Z6 --no-owner --no-privileges -f hive-rds-$TS.dump
shasum -a 256 hive-rds-$TS.dump | tee hive-rds-$TS.dump.sha256
```

Beklenen: `.counts` tek satır; `pg_restore --list hive-rds-$TS.dump | grep -c "TABLE DATA"` → `3`.

## 4. Veri doğru mu? (salt okunur sorgular, port-forward üzerinden)

**Botun yazdığı her kayıt var mı?** Bot her yazmaya artan bir numara koyuyor (`note = bot-chem-<n>`):

```sql
select count(*) as satir, count(distinct n) as tekil, min(n), max(n),
       max(n) - min(n) + 1 - count(distinct n) as aralikta_eksik
from (select substring(note from 'bot-chem-(\d+)')::int n
      from movements where note like 'bot-chem-%') t;
```

`aralikta_eksik = 0` olmalı; değilse eksik numaralar:

```sql
select s.n from generate_series(
  (select min(substring(note from 'bot-chem-(\d+)')::int) from movements where note like 'bot-chem-%'),
  (select max(substring(note from 'bot-chem-(\d+)')::int) from movements where note like 'bot-chem-%')) s(n)
where not exists (select 1 from movements where note = 'bot-chem-' || s.n)
order by 1 limit 50;
```

**Tekrar yazılmış kayıt var mı?** (göç sırasında aynı hareket iki kez kopyalandıysa)

```sql
select note, count(*) from movements where note like 'bot-chem-%'
group by 1 having count(*) > 1 order by 2 desc limit 20;
```

Bilinen istisna: eski sistemde `bot-chem-1` … `bot-chem-5` ikişer kez var (bot 10:49 UTC'de yeniden
başladığında "önceki loglardan devam, seq 6'dan başlıyor"). Bunlar göçten önce, kaynakta oluşmuş; göç hatası değil.

**Eski sunucudaki kayıtların hepsi taşındı mı?** Eski DB'nin son dump'ı ile karşılaştırma, lokal container'da:

```bash
docker run -d --name hive-verify -e POSTGRES_PASSWORD=x postgres:16-alpine
until docker exec hive-verify pg_isready -U postgres -q; do sleep 1; done
docker exec hive-verify createdb -U postgres legacy
docker exec hive-verify createdb -U postgres rds
docker exec -i hive-verify pg_restore -U postgres -d legacy --no-owner < hive-legacy-<TS>.dump
docker exec -i hive-verify pg_restore -U postgres -d rds --no-owner < hive-rds-<TS>.dump
docker exec hive-verify psql -U postgres -d rds -XAtc "create extension if not exists dblink;
  select count(*) as legacyde_olup_rdste_olmayan from dblink('dbname=legacy user=postgres',
    'select id, product_id, delta, note, created_at from movements')
    as l(id int, product_id int, delta int, note text, created_at timestamp)
  where not exists (select 1 from movements m where m.id = l.id
    and m.product_id = l.product_id and m.delta = l.delta and m.note is not distinct from l.note);"
docker rm -f hive-verify
```

Beklenen: `0`. Eski sistemdeki her hareket aynı id, ürün, miktar ve notla RDS'te.

**Stok ile hareketler tutarlı mı?** Göçten sonraki dönemde her ürünün stok değişimi, o dönemdeki hareketlerin toplamına eşit olmalı:

```sql
select r1.generated_at, r2.generated_at, r2.total_quantity - r1.total_quantity as rapor_farki,
  (select coalesce(sum(delta),0) from movements m
     where m.created_at > r1.generated_at and m.created_at <= r2.generated_at) as hareket_toplami
from daily_reports r1 join daily_reports r2 on r2.id = (select min(id) from daily_reports where id > r1.id)
order by r1.generated_at desc limit 12;
```

`rapor_farki = hareket_toplami` beklenir (±birkaç: rapor anında süren yazmalar).

## 5. Kapat

Port-forward terminalinde `Ctrl-C`. `unset PGPASSWORD`. Dump dosyaları müşteri verisidir: şifreli diskte tutun, paylaşmayın.
Bastion kullanılmayacaksa `enable_bastion = false` ile kaldırılır.
