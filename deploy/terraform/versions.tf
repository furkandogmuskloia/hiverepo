terraform {
  required_version = ">= 1.5"

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
