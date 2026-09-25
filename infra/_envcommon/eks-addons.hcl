terraform {
  source = "tfr:///aws-ia/eks-blueprints-addons/aws?version=1.24.3"
}

locals {
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  prefix           = local.environment_vars.inputs.prefix
}

inputs = {
  // ALB -> pod IP; rolling update'te hedefler kesintisiz değişir.
  enable_aws_load_balancer_controller = true

  // RDS bağlantı secret'ını Secrets Manager'dan Kubernetes'e taşır.
  enable_external_secrets = true

  enable_metrics_server = true

  // GitOps: uygulama manifest'leri repodan ArgoCD ile senkronlanır.
  enable_argocd = true
  argocd = {
    values = [yamlencode({
      configs = {
        params = { "server.insecure" = true }
      }
    })]
  }

  tags = local.environment_vars.inputs.tags
}
