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
  type    = number
  default = 2
}

variable "node_spot_max_size" {
  type    = number
  default = 7
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "acm_certificate_arn" {
  description = "Bos birakilirsa ALB sadece HTTP dinler. Dolu ise 443 + HTTP->HTTPS yonlendirme acilir."
  type        = string
  default     = ""
}
