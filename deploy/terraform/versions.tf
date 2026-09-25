terraform {
  required_version = ">= 1.10"

  # State S3'te: ekipten birden fazla kisi apply edebilsin ve kimin ne
  # uyguladigi izlenebilsin. Lokal state ile paralel apply'lar birbirini
  # gormuyordu.
  #
  # Bucket'ta versioning ACIK - bozuk state'ten donmenin tek yolu.
  # use_lockfile S3'un kendi kilit mekanizmasini kullanir; ayri bir
  # DynamoDB tablosu gerekmiyor (terraform >= 1.10).
  backend "s3" {
    bucket       = "hive-tfstate-417732881703"
    key          = "hive/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    time       = { source = "hashicorp/time", version = "~> 0.12" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = local.tags
  }
}

# helm provider v3 attribute sozdizimi kullanir (v2'deki blok degil).
# eks-blueprints-addons modulu helm >= 3.0 sart kosuyor.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
  }
}
