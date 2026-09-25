# HIVE — depo stok takip servisi

Umbrella Chemical (eu-central-1) HIVE uygulamasının kodu, container imajı, altyapısı ve deploy
yöntemi. Geçmiş kararlar ve gerekçeler: [`docs/history.md`](docs/history.md).

## Son durum — 2026-09-25

| Bileşen | Ne | Durum |
|---|---|---|
| Eski ortam | EC2 `umb-app-01` (uygulama + PostgreSQL 15 aynı makinede) | **Canlı**, puanlama botu buraya yazıyor. Gün sonuna kadar kapatılmayacak |
| VPC | `hive-vpc` 10.20.0.0/16, 3 AZ, public / private / database subnet'leri, tek NAT | Uygulandı |
| EKS | `hive` (1.36), Graviton (arm64) node'lar: on-demand + spot, cluster-autoscaler | Uygulandı |
| Addon'lar | AWS Load Balancer Controller, metrics-server, cluster-autoscaler | Uygulandı |
| RDS | `hive-pg` PostgreSQL 16, tek AZ, şifreli, internete kapalı; şifre Secrets Manager'da | Uygulandı, **boş** (veri göçü yapılmadı) |
| ECR | `hive`, immutable tag | Uygulandı; ilk imaj `20260925-131428` |
| Uygulama | `hive` namespace, 2 pod, HPA, PDB, NetworkPolicy, internet-facing ALB | **Çalışıyor**, `/health` 200 |
| ArgoCD | `deploy/k8s`'i izleyen GitOps | Planlandı: `enable_argocd` main'de, `terraform apply` bekleniyor |
| Veri göçü | EC2 PostgreSQL → RDS | Planlandı |
| Trafik geçişi | Bot/istemcilerin yeni ALB'ye yönlendirilmesi | Planlandı |

**Değişmeyen:** eski sunucu, onun veritabanı ve cron işleri. Göç tamamlanana kadar hiçbirine dokunulmaz.

**Bilinen açıklar:** Terraform state lokalde (remote backend yok); EKS API endpoint public;
trivy bulguları `.trivyignore`'da gerekçesiyle kabul edildi.

## Mimari

```
internet ── ALB (internet-facing) ── EKS pod'ları (private subnet, arm64) ── RDS PostgreSQL (database subnet)
                                          │
                                          └─ Secrets Manager (DB şifresi) → k8s secret hive-db
```

| Klasör | İçerik |
|---|---|
| `main.go` | Uygulama. `/health` DB'ye bakar (readiness), `/healthz` sadece süreç (liveness) |
| `Dockerfile` | arm64 statik binary, distroless, nonroot |
| `deploy/terraform/` | VPC, EKS, RDS, ECR, addon'lar |
| `deploy/k8s/` | Kubernetes manifest'leri (kustomize) — ArgoCD'nin izlediği klasör |
| `deploy/argocd/` | ArgoCD Application tanımı |
| `deploy/deploy.sh` | İmaj build/push + secret + manifest uygulama |
| `.github/workflows/` | `app-ci`, `infra-ci` — bkz. [`docs/ci-cd.md`](docs/ci-cd.md) |

## Uygulama ayarları (ortam değişkenleri)

| Değişken | Varsayılan | Not |
|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` | `localhost`, `5432`, `hive`, `hive` | |
| `DB_PASSWORD` | — | **Zorunlu**, yoksa uygulama açılmaz |
| `DB_SSLMODE` | `require` | Eski sunucudaki lokal Postgres için `disable` |
| `DB_MAX_OPEN_CONNS` | `5` | Pod başına bağlantı tavanı |
| `DB_CONNECT_TIMEOUT` | `2m` | Açılışta DB'yi bu süre boyunca bekler |
| `HIVE_SEED_SAMPLE_DATA` | `false` | `true` ise boş DB'ye 18 örnek ürün yazar. **Göç sırasında kapalı kalmalı** |
| `HIVE_API_TOKEN` | boş | Doluysa `POST /api/stock` bearer token ister. **Göç sırasında boş kalmalı**: puanlama botu token göndermiyor |

## Deploy runbook

### Önkoşullar
- Repo kökünde olun (`git pull origin main`).
- AWS kimliği: `export AWS_PROFILE=<takım-profili>`; `aws sts get-caller-identity` hesabı `417732881703` göstermeli.
- EKS erişimi: kullanıcınızın cluster'da access entry'si olmalı (`aws eks list-access-entries --cluster-name hive`).
- Docker (arm64 build; Apple Silicon üzerinde native).
- Terraform state'i olmayan bir makineden çalıştırıyorsanız değerleri ortam değişkeniyle verin (aşağıda).

### 1. Değerleri topla (salt okunur)

```bash
aws rds describe-db-instances --db-instance-identifier hive-pg --region eu-central-1 \
  --query 'DBInstances[0].{host:Endpoint.Address,secret:MasterUserSecret.SecretArn}'
```

Beklenen: `host` = `hive-pg.<id>.eu-central-1.rds.amazonaws.com`, `secret` = `arn:aws:secretsmanager:...:secret:rds!db-...`.

### 2. Deploy (ilk değişiklik bu adımda)

Ayrı bir kubeconfig kullanın; varsayılan context'iniz değişmesin.

```bash
KUBECONFIG=$HOME/.kube/hive.yaml \
  HIVE_API_TOKEN= \
  REGION=eu-central-1 \
  CLUSTER=hive \
  ECR_URL=417732881703.dkr.ecr.eu-central-1.amazonaws.com/hive \
  DB_HOST=<1. adımdaki host> \
  DB_PORT=5432 \
  DB_NAME=hive \
  DB_USER=hive \
  SECRET_ARN='<1. adımdaki secret>' \
  VPC_CIDR=10.20.0.0/16 \
  ./deploy/deploy.sh
```

Terraform state'i olan makinede sadece `./deploy/deploy.sh` yeterli; değerler `terraform output`'tan okunur.

Beklenen çıktı (2026-09-25 13:14 UTC gerçek çalıştırma):
- `naming to .../hive:<YYYYMMDD-HHMMSS> done` ve `<tag>: digest: sha256:...` (push)
- `secret/hive-db hazir`
- `deployment "hive" successfully rolled out`
- `==> HAZIR` ve `URL : http://k8s-hive-hive-....eu-central-1.elb.amazonaws.com`

İlk ALB oluşumunda DNS 2–3 dk gecikebilir.

### 3. Doğrula (salt okunur)

```bash
kubectl -n hive get pods -o wide
kubectl -n hive logs deploy/hive --tail=5
curl -s http://<ALB>/health
```

Beklenen: pod'lar `1/1 Running`; logda `connected to db at hive-pg...`; `{"status":"ok"}`.
DB boşsa logda `sample data disabled` görünür ve `/api/stock` `[]` döner — göç öncesi beklenen durum.

### 4. Geri al

```bash
kubectl -n hive rollout undo deployment/hive
kubectl -n hive rollout status deployment/hive
```

ArgoCD devreye girdikten sonra geri alma: `deploy/k8s/kustomization.yaml` içindeki `newTag`'i
önceki değere çeken bir commit; ArgoCD senkronlar.

## ArgoCD'ye geçiş

1. `terraform -chdir=deploy/terraform apply` — ArgoCD'yi kurar; uygulamaya dokunmaz.
2. `deploy/k8s/kustomization.yaml` → `newTag:` şu an çalışan tag (ör. `20260925-131428`), main'e commit.
   Bu adım 3'ten önce yapılmalı; aksi halde ArgoCD ECR'da olmayan `latest`'i arar.
3. `kubectl apply -f deploy/argocd/application.yaml`
4. `kubectl -n argocd get applications.argoproj.io hive` → `Synced` / `Healthy`. Pod'lar yeniden başlamaz.
