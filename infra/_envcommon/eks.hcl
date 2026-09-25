terraform {
  source = "tfr:///terraform-aws-modules/eks/aws?version=21.26.0"
}

locals {
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  account_vars     = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  prefix           = local.environment_vars.inputs.prefix
  admin_principals = local.account_vars.inputs.eks_admin_principal_arns
}

inputs = {
  name               = format("%s-eks", local.prefix)
  kubernetes_version = "1.33"

  // GitHub Actions (addons unit'i helm ile kurar) ve takım erişimi için public endpoint.
  endpoint_public_access  = true
  endpoint_private_access = true

  // Cluster'ı oluşturan Actions rolü cluster-admin olur.
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for i, arn in local.admin_principals : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni                = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      // 3 AZ'ye yayılır; rolling update sırasında en az 2 node ayakta kalır.
      min_size     = 2
      desired_size = 3
      max_size     = 5

      update_config = { max_unavailable = 1 }
    }
  }
}
