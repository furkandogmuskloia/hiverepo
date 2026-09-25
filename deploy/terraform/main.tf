locals {
  name = var.name

  # ilk 3 normal AZ. opt-in filtresi eu-central-1-ist-1a local zone'unu eler -
  # local zone'da EKS node group ve RDS subnet group desteklenmiyor.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project   = "hive"
    App       = "hive-stock"
    ManagedBy = "terraform"
    Env       = "hackathon"
  }

  # gp3 - gp2'den ucuz ve daha hizli
  node_block_device_mappings = {
    root = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = 20
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  # EKS bu etiketleri altindaki ASG'ye tasir; Cluster Autoscaler
  # auto-discovery tam olarak bunlara bakiyor.
  node_autoscaler_tags = {
    "k8s.io/cluster-autoscaler/enabled"       = "true"
    "k8s.io/cluster-autoscaler/${local.name}" = "owned"
  }

  # EKS ayrica eks.amazonaws.com/capacityType etiketini otomatik basiyor,
  # ama pod'larin topology spread'i bu kisa etikete gore yaziliyor.
  node_labels_ondemand = { capacity = "ondemand" }
  node_labels_spot     = { capacity = "spot" }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # node'lar private, ALB public, RDS ayri bir database katmaninda
  private_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  public_subnets   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 101)]
  database_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 201)]

  create_database_subnet_group = true

  # tek NAT: hackathon icin hiz ve maliyet. Prod'da AZ basina bir tane olmali.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # AWS Load Balancer Controller subnet'leri bu etiketlerle kesfeder
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# EKS
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # laptop'tan kubectl icin public endpoint acik, ama hangi IP'lerden
  # erisilebilecegi eks_public_access_cidrs ile daraltiliyor.
  # endpoint_private_access varsayilan olarak acik: cluster icinden erisim
  # (ArgoCD, controller'lar, pod'lar) bu listeden ETKILENMEZ.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs

  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Cluster'i kuran (halil.bozan) zaten admin - bkz.
  # enable_cluster_creator_admin_permissions. Ekip uyeleri buradan eklenir.
  # EKS API authentication mode kullaniliyor, aws-auth ConfigMap'e gerek yok.
  access_entries = merge({
    for name in var.eks_admin_users : replace(name, ".", "-") => {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${name}"
      type          = "STANDARD"

      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    }, {
    # GitHub Actions (github-actions.tf): plan salt-okunur gorur (helm release
    # secret'lari dahil), apply cluster-admin.
    gha-plan = {
      principal_arn = aws_iam_role.gha["hive-gha-plan"].arn
      policy_associations = {
        view = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    gha-apply = {
      principal_arn = aws_iam_role.gha["hive-gha-apply"].arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  })

  # most_recent: EKS'in o surum icin "varsayilan" addon'unu degil, uyumlu
  # en guncel addon surumunu kurar.
  addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    vpc-cni = {
      most_recent = true
      # node'lardan once kurulmali, yoksa pod'lar IP alamaz
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  eks_managed_node_groups = {
    # taban kapasite - spot geri alinsa bile bu node'lar ayakta kalir
    ondemand = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_ondemand_min_size
      max_size     = var.node_ondemand_max_size
      desired_size = var.node_ondemand_desired_size

      labels                = local.node_labels_ondemand
      block_device_mappings = local.node_block_device_mappings
      tags                  = local.node_autoscaler_tags
    }

    # buyume kapasitesi - CA once buradan node ekler
    spot = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "SPOT"

      min_size     = var.node_spot_min_size
      max_size     = var.node_spot_max_size
      desired_size = var.node_spot_desired_size

      labels                = local.node_labels_spot
      block_device_mappings = local.node_block_device_mappings
      tags                  = local.node_autoscaler_tags
    }
  }

  tags = local.tags
}
