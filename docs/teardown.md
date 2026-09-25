# Ortamı kaldırma (teardown) — chem / eu-central-1

## Son durum — 2026-09-25

| Kaynak | Nasıl kaldırılır | Durum |
|---|---|---|
| ArgoCD uygulamaları (`hive`, `hive-monitoring`, `kube-prometheus-stack`) | 1. adım | Bekliyor |
| ALB `k8s-hive-hive-*` + target group + SG + ona bağlı 3 EIP | 1. adım (Ingress silinince controller kaldırır), EIP'ler 5. adım | Bekliyor |
| RDS `hive-pg` koruması | 2. adım (bu PR: `deletion_protection=false`, `skip_final_snapshot=true`, `delete_automated_backups=true`) | Bekliyor |
| VPC, NAT, EKS, node group'lar, RDS, ECR (15 imaj), bastion, IAM rolleri, SNS, alarmlar, `chem.kloia.me` kaydı | 3. adım `terraform destroy` | Bekliyor |
| S3 `hive-tfstate-417732881703` | 6. adım, en son (state buradayken silinmez) | Bekliyor |
| Eski sunucu `umb-app-01` (`i-0341e1804d7d4cc36`) | Organizatör kapattı | ✅ `terminated` |

**Dokunulmayacak:** `pharma-*` / `health-*` kaynakları, `anyo-vpc`, hesabın GitHub OIDC provider'ı (ortak),
`hive-binary-417732881703-eu-west-2-an` bucket'ı (organizatörün; sorulmadan silinmez).

**Veri:** final snapshot alınmıyor (ekip kararı). Son kopya: `dumps/hive-pg-20260925T164215Z.dump`,
2026-09-25 16:42 UTC, 416.200 hareket, restore ile doğrulandı, sha256 `f464590a…74e3997c`. Dump müşteri verisidir;
saklama/silme kararı ayrıca verilir.

Sıra önemli: ALB'yi Terraform değil, EKS içindeki Load Balancer Controller oluşturdu. EKS önce silinirse ALB,
target group ve SG sahipsiz kalır; ağ arayüzleri VPC'nin silinmesini engeller ve destroy yarıda takılır.

## Önkoşullar

```bash
export AWS_PROFILE=<profil> AWS_REGION=eu-central-1
export KUBECONFIG=$HOME/.kube/hive-chem.yaml
aws sts get-caller-identity --query Account --output text   # 417732881703
kubectl config current-context                             # hive cluster'ı
```

## 1. Uygulamaları ve ALB'yi kaldır

ArgoCD uygulamaları silinmezse selfHeal Ingress'i geri getirir.

```bash
kubectl -n argocd delete applications.argoproj.io hive hive-monitoring kube-prometheus-stack
kubectl -n hive delete ingress hive
```

Doğrula (2–3 dk içinde boş dönmeli):

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-hive')].LoadBalancerName" --output text
```

## 2. RDS korumasını kaldır (bu PR)

PR merge edildikten sonra, sadece RDS'e:

```bash
terraform -chdir=deploy/terraform plan -target=module.rds
terraform -chdir=deploy/terraform apply -target=module.rds
```

Beklenen plan: `module.rds...aws_db_instance.this[0]` **update in-place**
(`deletion_protection: true -> false`, `skip_final_snapshot: false -> true`, `delete_automated_backups: false -> true`).
`destroy` görünmemeli. Doğrula: `aws rds describe-db-instances --db-instance-identifier hive-pg --query 'DBInstances[0].DeletionProtection'` → `false`.

## 3. Terraform destroy

```bash
terraform -chdir=deploy/terraform plan -destroy -out=destroy.plan
terraform -chdir=deploy/terraform apply destroy.plan
```

Plan'da yalnızca `hive*` kaynakları olmalı. `pharma`, `health`, `anyo` geçen bir satır varsa **durun**.
Süre ~15–25 dk (EKS node group'lar ve RDS en uzunları).

## 4. Doğrula

```bash
aws eks list-clusters --query 'clusters' --output text                       # hive yok
aws rds describe-db-instances --query "DBInstances[?DBInstanceIdentifier=='hive-pg']" --output text
aws ec2 describe-vpcs --filters Name=tag:Name,Values=hive-vpc --query 'Vpcs[].VpcId' --output text
aws ecr describe-repositories --query "repositories[?repositoryName=='hive']" --output text
aws iam list-roles --query "Roles[?starts_with(RoleName,'hive')].RoleName" --output text
dig +short chem.kloia.me                                                    # boş
```

Hepsi boş dönmeli.

## 5. Artıklar

ALB'ye bağlı olan 3 Elastic IP (`18.195.68.87`, `3.126.20.171`, `63.188.121.63`) Terraform'da değil.
ALB gittikten sonra boşta kalırlarsa bırakılır:

```bash
aws ec2 describe-addresses \
  --query "Addresses[?AssociationId==null].[PublicIp,AllocationId]" --output text
aws ec2 release-address --allocation-id <allocation-id>
```

KMS anahtarları (EKS secret şifrelemesi) hemen silinemez; AWS 7–30 gün "pending deletion" bekletir, bu normaldir.

## 6. State bucket (en son)

Versioning açık olduğu için tüm sürümlerle birlikte silinir. **Geri alınamaz**; bundan sonra Terraform ile hiçbir şey
yönetilemez.

```bash
aws s3api delete-objects --bucket hive-tfstate-417732881703 \
  --delete "$(aws s3api list-object-versions --bucket hive-tfstate-417732881703 \
    --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' --output json)"
aws s3api delete-bucket --bucket hive-tfstate-417732881703
```

## Geri alma

1–2. adımlar geri alınabilir (PR revert + ArgoCD app'lerini yeniden uygulamak). 3. adımdan sonra ortam ancak
sıfırdan kurulup dump'tan geri yüklenerek döner.
