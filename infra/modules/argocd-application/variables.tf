variable "name" {
  description = "ArgoCD Application name"
  type        = string
}

variable "repo_url" {
  description = "Git repository ArgoCD syncs from"
  type        = string
}

variable "target_revision" {
  description = "Branch, tag or commit to track"
  type        = string
  default     = "main"
}

variable "path" {
  description = "Path to the kustomize overlay inside the repository"
  type        = string
}

variable "destination_namespace" {
  description = "Namespace the application is deployed into"
  type        = string
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD runs in"
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "argocd-apps Helm chart version"
  type        = string
  default     = "2.0.5"
}
