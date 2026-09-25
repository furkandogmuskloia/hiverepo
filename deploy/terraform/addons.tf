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
    # Modulun varsayilani v2.7.1 (Subat 2024) - EKS 1.36 icin fazla eski.
    chart_version = "3.5.0"

    set = [
      # KRITIK: controller VPC ID'yi normalde EC2 IMDS'ten okur. Node'larda
      # HttpPutResponseHopLimit=1 oldugu icin pod IMDS'e ulasamiyor (401) ve
      # controller CrashLoopBackOff'a giriyordu. Hop limitini 2 yapmak yerine
      # degeri dogrudan veriyoruz - pod'larin IMDS'e erisememesi guvenlik
      # acisindan zaten istenen durum.
      {
        name  = "vpcId"
        value = module.vpc.vpc_id
      },
      {
        name  = "region"
        value = var.region
      },
      {
        name  = "enableServiceMutatorWebhook"
        value = "false"
      }
      # nodeSelector kaldirildi: tum node'lar zaten arm64, ayrica helm set
      # icindeki kacisli nokta sozdizimi kirilgandi.
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
    # Modulun varsayilani 5.55.0 (ArgoCD ~v2.10, 2024 basi) - EKS 1.36 icin
    # eski. ALB controller'da yasanan "modulun bayat chart varsayilani"
    # sorununun aynisi; surum acikca pinleniyor.
    chart_version = "10.9.2" # ArgoCD v3.5.3

    values = [yamlencode({
      configs = {
        params = { "server.insecure" = true }
      }
    })]
  }

  tags = local.tags
}
