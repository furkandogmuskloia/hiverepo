# CI/CD

İki hat var; ikisi de her PR'da çalışır, sorunlar merge'den önce yakalanır (shift-left).

| Workflow | Tetikleyici | PR'da | main'de |
|---|---|---|---|
| `app-ci` | uygulama kodu, Dockerfile | gofmt, vet, staticcheck, test, govulncheck, gitleaks, gosec, hadolint, trivy (config + imaj) | + imajı `linux/arm64` + `linux/amd64` olarak GHCR'a, tanımlıysa ECR'a push |
| `infra-ci` | `deploy/terraform/**` | terraform fmt, validate, tflint, trivy misconfig | aynı kontroller |

## Henüz olmayan: plan/apply

`deploy/terraform` şu an remote backend kullanmıyor (state lokalde). Brief'e göre altyapı
**sadece GitHub Actions üzerinden** apply edilmeli ve state bucket'a sadece Actions rolü yazabiliyor.
Bunun için:

1. `deploy/terraform`'a S3 backend eklenmeli ve mevcut lokal state oraya taşınmalı
   (`terraform init -migrate-state`, state sahibinin yapması gerekir).
2. `aws_profile` CI'da boş geçilmeli (`TF_VAR_aws_profile=""`); Actions OIDC ile kimlik alır.
3. `infra-ci`'ya plan (PR'a yorum) ve apply (main, `production` onayı) job'ları eklenmeli.

## Gerekli repo ayarları

Settings → Secrets and variables → Actions → **Variables**:

| Değişken | Örnek | Kullanan |
|---|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::<hesap>:role/<actions-rolu>` | `app-ci` (ECR push) |
| `ECR_REPOSITORY` | `terraform output ecr_repository_url`'deki repo adı | `app-ci` |

Değişkenler tanımlı değilse ECR adımları atlanır, hat kırılmaz; imaj yalnızca GHCR'a gider.

## Lokal

```bash
pip install pre-commit
pre-commit install
```

Commit öncesi gitleaks, gofmt/vet, hadolint ve terraform fmt çalışır.
