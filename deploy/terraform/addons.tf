################################################################################
# AWS resmi addon modulu (aws-ia) - IRSA rollerini de kendisi kuruyor
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.24"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # Ingress kaynaklarini gercek ALB'ye ceviren controller
  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    set = [
      {
        name  = "enableServiceMutatorWebhook"
        value = "false"
      },
      # controller'in kendisi de arm64 node'a dusmeli
      {
        name  = "nodeSelector.kubernetes\\.io/arch"
        value = "arm64"
      }
    ]
  }

  # NODE bazinda olceklenme: bekleyen pod varsa ASG'ye node ekler
  enable_cluster_autoscaler = true
  cluster_autoscaler = {
    set = [
      # priority expander: once spot grubunu dener, kapasite yoksa ondemand.
      # Oncelik tablosu autoscaler-priority.tf'teki ConfigMap'te.
      {
        name  = "extraArgs.expander"
        value = "priority"
      },
      {
        name  = "extraArgs.scale-down-unneeded-time"
        value = "2m"
      },
      {
        name  = "extraArgs.scale-down-delay-after-add"
        value = "2m"
      },
      # ayni gruptaki AZ'ler arasinda node sayisini dengeler
      {
        name  = "extraArgs.balance-similar-node-groups"
        value = "true"
      }
    ]
  }

  # POD bazinda olceklenme icin sart: HPA CPU metrigini buradan okur
  enable_metrics_server = true

  # GitOps: deploy/k8s repodan senkronlanir (deploy/argocd/application.yaml).
  # UI'a port-forward ile erisilir; disari acilmaz.
  enable_argocd = true
  argocd = {
    values = [yamlencode({
      configs = {
        params = { "server.insecure" = true }
      }
    })]
  }

  tags = local.tags
}
