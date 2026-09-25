# CI/CD

İki hat var; ikisi de her PR'da çalışır, sorunlar merge'den önce yakalanır (shift-left).

| Workflow | Tetikleyici | PR'da | main'de |
|---|---|---|---|
| `app-ci` | uygulama kodu, Dockerfile | gofmt, vet, staticcheck, test, govulncheck, gitleaks, gosec, hadolint, trivy (config + imaj) | + imajı GHCR'a, tanımlıysa ECR'a push; overlay'deki imaj tag'ini commit SHA'ya çeker (GitOps) |
| `infra-ci` | `infra/**` | fmt, validate, tflint, trivy misconfig, plan (PR'a yorum) | + `production` onayı arkasında apply |

`terraform apply` yalnızca `infra-ci` üzerinden yapılır; state bucket'a sadece Actions rolü yazabilir.
Altyapı Terragrunt ile `infra/` altında; ayrıntı ve runbook: `infra/README.md`.

## Gerekli repo ayarları

Settings → Secrets and variables → Actions → **Variables**:

| Değişken | Örnek | Kullanan |
|---|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::<hesap>:role/<actions-rolu>` | `app-ci` (ECR push) |
| `ECR_REPOSITORY` | `chem-hive` | `app-ci` |
| `TF_ROLE_ARN` | `arn:aws:iam::<hesap>:role/<actions-rolu>` | `infra-ci` (plan/apply) |
| `TF_STATE_BUCKET` | organizatörün verdiği bucket | `infra-ci` (Terragrunt backend) |

Değişkenler tanımlı değilse ilgili adımlar atlanır, hat kırılmaz: imaj yalnızca GHCR'a gider, plan/apply çalışmaz.

Settings → Environments → **production**: required reviewer ekleyin; apply bu onaydan sonra başlar.

AWS tarafında Actions rolünün trust policy'si bu repoya güvenmelidir
(`token.actions.githubusercontent.com:sub` = `repo:<org>/<repo>:*`).

## Lokal

```bash
pip install pre-commit
pre-commit install
```

Commit öncesi gitleaks, gofmt/vet, hadolint ve terraform fmt çalışır.
