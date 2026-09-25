# HIVE altyapısı — chem / eu-central-1

## Son durum — 2026-09-25

| Unit | Ne kurar | Durum |
|---|---|---|
| `vpc` | `chem-hive-vpc` 10.20.0.0/16, 3 AZ; public /24, private /20 (EKS), database /24; tek NAT | planlandı |
| `ecr` | `chem-hive` repo, immutable tag, push'ta tarama, son 30 imaj | planlandı |
| `rds` | `chem-hive-db` PostgreSQL 15, db.t4g.medium, **Multi-AZ**, 7 gün PITR, şifreli, public değil; bağlantı bilgisi Secrets Manager `chem-hive/db` | planlandı |
| `eks` | `chem-hive-eks` 1.33, 3x t3.medium (min 2, max 5), 3 AZ | planlandı |
| `eks-addons` | AWS Load Balancer Controller, External Secrets, metrics-server, ArgoCD | planlandı |
| `gitops-bootstrap` | ArgoCD Application `chem-hive` → `deploy/overlays/chem` | planlandı |

Hiçbiri henüz apply edilmedi. Hepsi `terragrunt validate` ile lokalde doğrulandı (backend'siz, mock output).

**Değişmeyen:** eski ortam (`umb-app-01`, 51.102.170.229) gün sonuna kadar olduğu gibi çalışır.

**Bloke:** `TF_ROLE_ARN`, `TF_STATE_BUCKET` (organizatörden), ve Actions rolünün bu repoya güvenmesi.

## Yapı

```
infra/
├── root.hcl                     backend (S3, native lock) + aws provider, default tag'ler
├── _envcommon/<unit>.hcl        modül kaynağı + tüm ortamlarda aynı input'lar
├── modules/
│   ├── hive-database/           RDS + SG + Secrets Manager (şifre state'e girmez)
│   └── argocd-application/      ArgoCD Application (helm argocd-apps)
└── chem/
    ├── account.hcl, env.hcl
    └── eu-central-1/
        ├── region.hcl
        └── vpc/ ecr/ rds/ eks/ eks-addons/ gitops-bootstrap/
```

Apply sırası (Terragrunt bağımlılıklardan çıkarır): `vpc` → (`ecr`, `rds`, `eks` paralel) → `eks-addons` → `gitops-bootstrap`.

## Uygulama (sadece GitHub Actions)

Lokal apply yapılmaz; state bucket'a yalnızca Actions rolü yazabilir.

1. **Repo ayarları** (Settings → Secrets and variables → Actions → Variables):
   `TF_ROLE_ARN`, `TF_STATE_BUCKET`, (gerekirse) `TF_STATE_BUCKET_REGION`,
   `AWS_ROLE_ARN`, `ECR_REPOSITORY=chem-hive`.
   Settings → Environments → `production` → required reviewer.
2. **PR aç** (`infra/**` değişikliği). `infra-ci` çalışır:
   - `static`: fmt, validate, tflint, trivy. Kimlik gerektirmez.
   - `plan`: PR'a yorum olarak düşer. Beklenen ilk plan: tüm unit'ler için yalnızca `add`, hiç `destroy` yok.
3. **Merge → `apply`** `production` onayından sonra başlar. İlk kurulum ~30 dk (EKS + RDS Multi-AZ).
4. **Uygulama imajı**: `app-ci` main'de imajı ECR'a iter ve `deploy/overlays/chem` içindeki tag'i commit SHA'ya çeker; ArgoCD bunu senkronlar.

## Doğrulama (salt okunur, takım rolüyle)

```bash
aws eks update-kubeconfig --name chem-hive-eks --region eu-central-1 --profile <takim-profili>
kubectl -n argocd get applications.argoproj.io chem-hive
kubectl -n hive get externalsecret,pods,ingress
```

Beklenen: Application `Synced` / `Healthy`; ExternalSecret `SecretSynced`; 3 pod `Running` ve `READY 1/1`;
Ingress `ADDRESS` alanında `chem-hive-alb-...elb.amazonaws.com`.

```bash
ALB=$(kubectl -n hive get ingress hive -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ALB/health"
```

Beklenen: `{"status":"ok"}`. Veri göçü bitmeden `/api/stock` boş liste döner; bu beklenen durum.

## Geri alma

- **Uygulama**: `deploy/overlays/chem/kustomization.yaml` içindeki `newTag`'i önceki SHA'ya çeken bir commit; ArgoCD geri senkronlar.
- **Trafik**: bot/istemciler hâlâ eski ortama gidiyorsa geri alınacak bir şey yok. Geçişten sonra eski ortama dönüş, geçiş planındaki DNS/yönlendirme adımının tersidir.
- **Altyapı**: `destroy` bu hattın bir parçası değil. RDS `deletion_protection = true`.

## Bilinen tercihler

- **Tek NAT gateway**: maliyet için. Bir AZ kaybında node'ların dışarı çıkışı gider; gelen trafik ve RDS etkilenmez.
- **Uygulama RDS master kullanıcısıyla bağlanır** (`hive`): göçün hızlı olması için. Sonraki adım: ayrı, yetkisi kısıtlı uygulama kullanıcısı.
- **Addon chart sürümleri** eks-blueprints-addons 1.24.3 varsayılanlarıdır (ArgoCD chart 5.55, ESO 0.9.13, LBC 1.7.1); ESO manifest'leri bu yüzden `v1beta1`.
- **EKS public endpoint açık**: Actions runner'ları sabit IP'den gelmiyor. Sonraki adım: self-hosted runner veya CIDR kısıtı.
