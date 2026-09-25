include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/eks.hcl"
}

dependency "vpc" {
  config_path = format("%s/../vpc", get_terragrunt_dir())

  mock_outputs = {
    vpc_id          = "vpc-00000000000000000"
    private_subnets = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  // CI statik doğrulamasında (kimlik bilgisi yok) state okunmaz, mock kullanılır.
  skip_outputs = get_env("TG_SKIP_OUTPUTS", "false") == "true"
}

inputs = {
  vpc_id     = dependency.vpc.outputs.vpc_id
  subnet_ids = dependency.vpc.outputs.private_subnets
}
