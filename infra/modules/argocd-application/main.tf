terraform {
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
  }
}

# ArgoCD'ye tek bir Application tanıtır (GitOps bootstrap). ArgoCD ve CRD'leri
# eks-addons unit'inde kurulu olmalı; bu yüzden ayrı unit, ayrı apply.
resource "helm_release" "apps" {
  name       = "${var.name}-apps"
  namespace  = var.argocd_namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_version

  values = [yamlencode({
    applications = {
      (var.name) = {
        namespace = var.argocd_namespace
        project   = "default"
        source = {
          repoURL        = var.repo_url
          targetRevision = var.target_revision
          path           = var.path
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.destination_namespace
        }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
          retry = {
            limit   = 5
            backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
          }
        }
      }
    }
  })]
}
