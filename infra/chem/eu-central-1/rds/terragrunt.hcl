include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rds.hcl"
}

// RDS yalnızca VPC'ye bağlı; EKS'i beklemez, ikisi paralel kurulur (~20-30 dk).
dependency "vpc" {
  config_path = format("%s/../vpc", get_terragrunt_dir())

  mock_outputs = {
    vpc_id                      = "vpc-00000000000000000"
    database_subnet_group_name  = "mock-db-subnet-group"
    private_subnets_cidr_blocks = ["10.20.16.0/20", "10.20.32.0/20", "10.20.48.0/20"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  // CI statik doğrulamasında (kimlik bilgisi yok) state okunmaz, mock kullanılır.
  skip_outputs = get_env("TG_SKIP_OUTPUTS", "false") == "true"
}

inputs = {
  vpc_id               = dependency.vpc.outputs.vpc_id
  db_subnet_group_name = dependency.vpc.outputs.database_subnet_group_name

  // Sadece EKS node/pod subnet'leri erişebilir; internetten erişim yok.
  allowed_cidr_blocks = dependency.vpc.outputs.private_subnets_cidr_blocks
}
