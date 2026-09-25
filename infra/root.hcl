// Layer 1: backend ve provider üretimi.
// Apply sadece GitHub Actions'tan yapılır: state bucket'a yalnızca Actions rolü yazabilir.

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  env          = local.env_vars.inputs.env
  region       = local.region_vars.inputs.region
  state_bucket = local.account_vars.inputs.state_bucket
  state_region = local.account_vars.inputs.state_bucket_region
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = local.state_bucket
    key          = "${local.env}/${path_relative_to_include()}/terraform.tfstate"
    region       = local.state_region
    encrypt      = true
    use_lockfile = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOT
    terraform {
      required_version = ">= 1.11.0"
    }

    provider "aws" {
      region = "${local.region}"

      default_tags {
        tags = ${jsonencode(local.env_vars.inputs.tags)}
      }
    }
  EOT
}
