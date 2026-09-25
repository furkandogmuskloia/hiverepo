#!/usr/bin/env bash
#
# HIVE -> EKS deploy. Terraform apply bittikten SONRA calistirilir.
#
#   ./deploy/deploy.sh
#
# Yaptiklari:
#   1. imaji derler ve ECR'a push eder (arm64/Graviton)
#   2. kubeconfig'i gunceller
#   3. RDS sifresini Secrets Manager'dan okuyup k8s secret'ina yazar
#   4. manifest'leri render edip uygular
#   5. rollout'u bekler ve ALB adresini basar
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/deploy/terraform"
K8S_DIR="$REPO_ROOT/deploy/k8s"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

export AWS_PROFILE="${AWS_PROFILE:-kloiadaas}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mHATA: %s\033[0m\n' "$*" >&2; exit 1; }

tf() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

# --- 0. terraform ciktilarini oku ----------------------------------------
say "Terraform ciktilari okunuyor"
REGION="$(tf region)"          || die "terraform output okunamadi - once 'terraform apply' calistir"
CLUSTER="$(tf cluster_name)"   || die "cluster_name bulunamadi"
ECR_URL="$(tf ecr_repository_url)"
DB_HOST="$(tf db_host)"
DB_PORT="$(tf db_port)"
DB_NAME="$(tf db_name)"
DB_USER="$(tf db_username)"
SECRET_ARN="$(tf db_master_user_secret_arn)"
VPC_CIDR="$(tf vpc_cidr_block)"

[ -n "$CLUSTER" ] || die "cluster adi bos"
echo "  cluster : $CLUSTER ($REGION)"
echo "  ecr     : $ECR_URL"
echo "  db      : $DB_HOST:$DB_PORT/$DB_NAME"

# --- 1. imaj derle + push ------------------------------------------------
# ECR repo IMMUTABLE - her push benzersiz etiket ister.
TAG="$(date -u +%Y%m%d-%H%M%S)"
IMAGE="$ECR_URL:$TAG"

say "ECR login"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ECR_URL%%/*}" >/dev/null

say "Imaj derleniyor: $IMAGE"
# Node'lar Graviton; Apple Silicon uzerinde native derlenir (emulasyon yok).
docker build --platform linux/arm64 -t "$IMAGE" "$REPO_ROOT"

say "ECR'a push ediliyor"
docker push "$IMAGE"

# --- 2. kubeconfig -------------------------------------------------------
say "kubeconfig guncelleniyor"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

# --- 3. namespace + secret ----------------------------------------------
say "Namespace"
kubectl apply -f "$K8S_DIR/namespace.yaml"

say "DB sifresi Secrets Manager'dan aliniyor"
DB_PASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" --region "$REGION" \
  --query SecretString --output text \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')"
[ -n "$DB_PASSWORD" ] || die "RDS sifresi okunamadi"

# API token: varsa korunur, yoksa uretilir (her deploy'da degismesin)
API_TOKEN="$(kubectl -n hive get secret hive-db \
  -o jsonpath='{.data.HIVE_API_TOKEN}' 2>/dev/null | base64 -d || true)"
if [ -z "$API_TOKEN" ]; then
  API_TOKEN="$(openssl rand -hex 24)"
  say "Yeni HIVE_API_TOKEN uretildi"
fi

kubectl -n hive create secret generic hive-db \
  --from-literal=DB_HOST="$DB_HOST" \
  --from-literal=DB_PORT="$DB_PORT" \
  --from-literal=DB_NAME="$DB_NAME" \
  --from-literal=DB_USER="$DB_USER" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=HIVE_API_TOKEN="$API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "  secret/hive-db hazir"

# --- 4. manifest'leri render et + uygula ---------------------------------
say "Manifest'ler uygulaniyor"
cp "$K8S_DIR"/*.yaml "$RENDER_DIR/"
# BSD sed (macOS) ve GNU sed arasinda -i farki var; dosyayi yeniden yaziyoruz
for f in "$RENDER_DIR"/*.yaml; do
  sed -e "s|__HIVE_IMAGE__|$IMAGE|g" -e "s|__VPC_CIDR__|$VPC_CIDR|g" "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
done

kubectl apply -f "$RENDER_DIR/"

# --- 5. bekle ------------------------------------------------------------
say "Rollout bekleniyor"
kubectl -n hive rollout status deployment/hive --timeout=5m

say "ALB adresi bekleniyor (1-3 dk surebilir)"
ALB=""
for i in $(seq 1 60); do
  ALB="$(kubectl -n hive get ingress hive -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$ALB" ] && break
  sleep 5
done
[ -n "$ALB" ] || die "ALB adresi alinamadi - 'kubectl -n hive describe ingress hive' ile bak"

say "HAZIR"
cat <<EOF

  URL        : http://$ALB
  Health     : curl http://$ALB/health
  Stok (GET) : curl http://$ALB/api/stock

  Stok hareketi (POST - token gerekli):
    curl -X POST http://$ALB/api/stock \\
      -H "Authorization: Bearer $API_TOKEN" \\
      -H 'Content-Type: application/json' \\
      -d '{"product_id":1,"delta":-5,"note":"eks test"}'

  Token   : $API_TOKEN
  Pods    : kubectl -n hive get pods -o wide
  HPA     : kubectl -n hive get hpa hive -w
  Nodes   : kubectl get nodes -L capacity,topology.kubernetes.io/zone

EOF
