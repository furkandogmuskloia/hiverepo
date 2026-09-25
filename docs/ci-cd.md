# CI/CD

İki hat var; ikisi de her PR'da çalışır, sorunlar merge'den önce yakalanır (shift-left).

| Workflow | Tetikleyici | PR'da | main'de |
|---|---|---|---|
| `app-ci` | uygulama kodu, Dockerfile | gofmt, vet, staticcheck, test, govulncheck, gitleaks, gosec, hadolint, trivy (config + imaj) | + imajı `linux/arm64` + `linux/amd64` olarak GHCR'a, tanımlıysa ECR'a push |
| `infra-ci` | `deploy/terraform/**` | terraform fmt, validate, tflint, trivy + plan (PR yorumu) | + onaylı apply (`production`) |

## Altyapı: plan ve apply sadece Actions'tan

| Olay | Ne olur |
|---|---|
| `deploy/terraform/**` değiştiren PR | statik kontroller + `terraform plan`; plan PR'a yorum olarak düşer, destroy/replace varsa uyarı ile |
| main'e merge | plan + **`production` onayı bekleyen** apply job'u; onaydan sonra plan yeniden alınır ve o plan uygulanır |
| Aynı anda iki çalışma | `concurrency: terraform-hive` ile sıraya girer, iptal edilmez |

**Sıra (bir kez):**
1. S3 backend'li Terraform main'de (state: `hive-tfstate-<hesap>`), `terraform plan` → `No changes`.
2. OIDC rolleri (`github-actions.tf`) **tek seferlik laptop apply** ile kurulur (bootstrap istisnası, tarih/saatle kayda geçer).
3. Repo değişkenleri ve `production` environment'ı oluşturulur (aşağıda).
4. İlk Actions çalışması **sadece plan**: `No changes` görülmeli.
5. Bundan sonra her altyapı değişikliği PR → plan → merge → onay → apply.
6. En son: state bucket'ına sadece Actions rolünün yazabildiği bucket policy.

**DNS cutover penceresinde başka hiçbir apply çalıştırılmaz** (state kilidi cutover'ı bloke edebilir).

## Gerekli repo ayarları

Settings → Secrets and variables → Actions → **Variables**:

| Değişken | Örnek | Kullanan |
|---|---|---|
| `TF_PLAN_ROLE_ARN` | `arn:aws:iam::<hesap>:role/hive-gha-plan` | `infra-ci` plan |
| `TF_APPLY_ROLE_ARN` | `arn:aws:iam::<hesap>:role/hive-gha-apply` | `infra-ci` apply (production) |
| `AWS_ROLE_ARN` | `arn:aws:iam::<hesap>:role/hive-gha-ecr` | `app-ci` (ECR push) |
| `ECR_REPOSITORY` | `terraform output ecr_repository_url`'deki repo adı | `app-ci` |

Değişkenler tanımlı değilse ECR adımları atlanır, hat kırılmaz; imaj yalnızca GHCR'a gider.

## Lokal

```bash
pip install pre-commit
pre-commit install
```

Commit öncesi gitleaks, gofmt/vet, hadolint ve terraform fmt çalışır.
