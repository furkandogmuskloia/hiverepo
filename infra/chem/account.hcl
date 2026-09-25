// Umbrella hackathon: üç takım aynı AWS hesabını (Kloia DaaS) paylaşıyor.
inputs = {
  account_id = "417732881703"

  // Organizatörün verdiği state bucket; CI'da repo variable TF_STATE_BUCKET ile gelir.
  state_bucket        = get_env("TF_STATE_BUCKET", "")
  state_bucket_region = get_env("TF_STATE_BUCKET_REGION", "eu-central-1")

  // EKS'e cluster-admin olarak eklenecek insan rolleri/kullanıcıları (takım rolü ARN'i gelince).
  eks_admin_principal_arns = []
}
