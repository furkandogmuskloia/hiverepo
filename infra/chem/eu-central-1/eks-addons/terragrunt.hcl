include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/eks-addons.hcl"
}

locals {
  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  region      = local.region_vars.inputs.region
}

dependency "eks" {
  config_path = format("%s/../eks", get_terragrunt_dir())

  mock_outputs = {
    cluster_name                       = "chem-hive-eks"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
    cluster_version                    = "1.33"
    oidc_provider_arn                  = "arn:aws:iam::417732881703:oidc-provider/oidc.eks.eu-central-1.amazonaws.com/id/MOCK"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  // CI statik doğrulamasında (kimlik bilgisi yok) state okunmaz, mock kullanılır.
  skip_outputs = get_env("TG_SKIP_OUTPUTS", "false") == "true"
}

dependency "rds" {
  config_path = format("%s/../rds", get_terragrunt_dir())

  mock_outputs = {
    app_secret_arn = "arn:aws:secretsmanager:eu-central-1:417732881703:secret:chem-hive/db-MOCK"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  // CI statik doğrulamasında (kimlik bilgisi yok) state okunmaz, mock kullanılır.
  skip_outputs = get_env("TG_SKIP_OUTPUTS", "false") == "true"
}

// helm/kubernetes provider'ları cluster'a EKS token ile bağlanır (Actions rolünün kimliğiyle).
generate "k8s_providers" {
  path      = "k8s-providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOT
    provider "kubernetes" {
      host                   = "${dependency.eks.outputs.cluster_endpoint}"
      cluster_ca_certificate = base64decode("${dependency.eks.outputs.cluster_certificate_authority_data}")
      exec {
        api_version = "client.authentication.k8s.io/v1beta1"
        command     = "aws"
        args        = ["eks", "get-token", "--cluster-name", "${dependency.eks.outputs.cluster_name}", "--region", "${local.region}"]
      }
    }

    provider "helm" {
      kubernetes = {
        host                   = "${dependency.eks.outputs.cluster_endpoint}"
        cluster_ca_certificate = base64decode("${dependency.eks.outputs.cluster_certificate_authority_data}")
        exec = {
          api_version = "client.authentication.k8s.io/v1beta1"
          command     = "aws"
          args        = ["eks", "get-token", "--cluster-name", "${dependency.eks.outputs.cluster_name}", "--region", "${local.region}"]
        }
      }
    }
  EOT
}

inputs = {
  cluster_name      = dependency.eks.outputs.cluster_name
  cluster_endpoint  = dependency.eks.outputs.cluster_endpoint
  cluster_version   = dependency.eks.outputs.cluster_version
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn

  // External Secrets yalnızca uygulamanın DB secret'ını okuyabilir.
  external_secrets_secrets_manager_arns = [dependency.rds.outputs.app_secret_arn]
}
