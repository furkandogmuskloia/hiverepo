variable "region" {
  description = "AWS bolgesi"
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profili"
  type        = string
  default     = "kloiadaas"
}

variable "name" {
  description = "Tum kaynaklar icin ad oneki"
  type        = string
  default     = "hive"
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS kontrol duzlemi surumu. 1.36 su an EKS'te cikmis en guncel surum;
    vpc-cni / coredns / kube-proxy / pod-identity-agent addon'larinin ve
    AL2023 arm64 AMI'sinin 1.36 destegi dogrulandi.
  EOT
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "node_instance_types" {
  description = <<-EOT
    Hepsi Graviton (arm64) - x86 muadillerine gore ~%20 ucuz, Apple Silicon
    uzerinde native derlenir (QEMU emulasyonu yok).
    Birden fazla tip verilmesi SPOT kapasite havuzunu derinlestirir:
    bir tipte kapasite bitince digerinden alinir, interrupt riski duser.
  EOT
  type        = list(string)
  default     = ["t4g.small", "t4g.medium", "m6g.medium"]
}

# ---------------------------------------------------------------------------
# Kapasite karisimi: ~%70 SPOT / ~%30 ON_DEMAND
#
# EKS managed node group'lar tek grup icinde mixed instances policy (yani
# OnDemandPercentageAboveBaseCapacity) DESTEKLEMIYOR - capacity_type ya SPOT
# ya ON_DEMAND. Oran bu yuzden iki ayri node group ile kuruluyor:
#   - ondemand grubu taban kapasite (kesintiye ugramaz)
#   - spot grubu buyume kapasitesi
# Cluster Autoscaler priority expander ile once SPOT'u dener, kapasite
# bulamazsa ON_DEMAND'a duser (bkz. autoscaler-priority.tf).
#
# Varsayilan steady state: 1 ondemand + 2 spot = %33 / %67.
# Tavanda: 3 ondemand + 7 spot = %30 / %70.
# ---------------------------------------------------------------------------

variable "node_ondemand_min_size" {
  type    = number
  default = 1
}

variable "node_ondemand_desired_size" {
  type    = number
  default = 1
}

variable "node_ondemand_max_size" {
  type    = number
  default = 3
}

variable "node_spot_min_size" {
  type    = number
  default = 1
}

variable "node_spot_desired_size" {
  # 2 -> 4: cluster 24/24 pod ile doldu (node basina 8 tavan) ve HPA'nin
  # buyume alani kalmadi. Prefix delegation yalnizca YENI node'lara
  # uygulandigi icin bu artis ayni zamanda yuksek tavanli node getiriyor.
  type    = number
  default = 4
}

variable "node_spot_max_size" {
  type    = number
  default = 7
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

# ---------------------------------------------------------------------------
# EKS erisimi
# ---------------------------------------------------------------------------

variable "eks_public_access_cidrs" {
  description = <<-EOT
    Kubernetes API'sine DISARIDAN erisebilecek CIDR'lar.

    endpoint_private_access zaten acik, yani cluster icindeki her sey
    (ArgoCD, controller'lar, pod'lar) bu listeden ETKILENMEZ. Burasi
    sadece laptop'tan gelen kubectl'i ilgilendiriyor.

    Su anki deger ekibin ortak cikis IP'si. Ag degisirse - baska mekan,
    VPN, evden baglanma - GUNCELLENMELI.

    Kilitlenme durumunda kurtarma (AWS API bu listeden etkilenmez):
      aws eks update-cluster-config --name hive --region eu-central-1 \
        --resources-vpc-config publicAccessCidrs=<yeni-ip>/32,endpointPublicAccess=true

    Not: GitHub Actions gibi CI runner IP'leri dinamiktir; cluster'a
    DISARIDAN erisen bir CI varsa allowlist onu kirar.
  EOT
  type        = list(string)
  default     = ["5.27.16.209/32"]
}

variable "eks_admin_users" {
  description = <<-EOT
    Cluster'a admin erisimi verilecek IAM kullanici adlari (ARN degil, sadece ad).
    Her biri icin EKS access entry + AmazonEKSClusterAdminPolicy olusturulur.
    Cluster'i kuran kullanici eklenmemeli, zaten admin.
  EOT
  type        = list(string)
  default     = ["furkan.dogmus"]
}

# ---------------------------------------------------------------------------
# DNS cutover (route53.tf)
# ---------------------------------------------------------------------------

variable "manage_dns" {
  description = <<-EOT
    chem.kloia.me A kaydini Terraform yonetsin mi.
    Mevcut kayit state'e import EDILDI, bu yuzden true guvenli.
    Yeni bir ortamda once import gerekir:
      terraform import 'aws_route53_record.chem[0]' \
        Z07389103CL53BOHXGNNK_chem.kloia.me_A
  EOT
  type        = bool
  default     = true
}

variable "cutover_to_eks" {
  description = <<-EOT
    false: chem.kloia.me eski EC2'ye (legacy_ip) bakar.
    true:  ALB'ye ALIAS. Geri alma ayni degiskeni false yapmak.
    Sadece manage_dns = true iken etkili.
  EOT
  type        = bool
  default     = false
}

variable "legacy_ip" {
  description = "Eski chem-hive EC2'sinin public IP'si"
  type        = string
  default     = "51.102.170.229"
}

variable "legacy_ttl" {
  type    = number
  default = 60
}

# HTTPS listener icin ayrildi; ingress henuz sadece HTTP.
# tflint-ignore: terraform_unused_declarations
variable "acm_certificate_arn" {
  description = "Bos birakilirsa ALB sadece HTTP dinler. Dolu ise 443 + HTTP->HTTPS yonlendirme acilir."
  type        = string
  default     = ""
}

variable "alert_emails" {
  description = "Alarm e-postalari (SNS). Her adres bir onay e-postasi alir; onaylanana kadar bildirim gitmez."
  type        = list(string)
  default     = []
}
