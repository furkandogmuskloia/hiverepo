terraform {
  source = "tfr:///terraform-aws-modules/ecr/aws?version=3.2.0"
}

locals {
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  prefix           = local.environment_vars.inputs.prefix
}

inputs = {
  repository_name = local.prefix

  // Aynı tag iki farklı imajı göstermesin; GitOps overlay commit SHA ile pin'ler.
  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true

  create_lifecycle_policy = true
  repository_lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Son 30 imajı tut"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
