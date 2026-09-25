################################################################################
# GitHub Actions -> AWS (OIDC). Statik access key yok; her calisma GitHub'in
# imzaladigi kisa omurlu token ile rol assume eder.
#
# Brief kurali: altyapi SADECE GitHub Actions uzerinden apply edilir. Bu dosya
# o yolu acan "bootstrap"tir: bir kez laptop'tan apply edilir, sonrasi Actions.
#
# Uc rol, uc yetki seviyesi:
#   hive-gha-plan   PR ve main'de plan  - salt okunur + state kilidi
#   hive-gha-apply  main'de apply       - sadece "production" environment onayindan sonra
#   hive-gha-ecr    main'de imaj push   - sadece hive ECR reposu
#
# OIDC provider hesapta zaten var (diger takimlar da kullaniyor): olusturulmaz,
# data source ile okunur. Baska takimin rolune dokunulmaz.
################################################################################

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # DIKKAT: repo'da "immutable subject claims" acik. Bu durumda GitHub'in
  # gonderdigi sub claim'i klasik "owner/repo" degil, hesap ve repo sayisal
  # ID'leriyle pinlenmis halidir - repo yeniden adlandirilinca eski erisim
  # devam etmesin diye:
  #
  #   klasik   : repo:furkandogmuskloia/hiverepo:ref:refs/heads/main
  #   gonderilen: repo:furkandogmuskloia@317830779/hiverepo@1387414537:ref:refs/heads/main
  #
  # Klasik formla yazilirsa eslesme HIC olmaz ve assume
  # "Not authorized to perform sts:AssumeRoleWithWebIdentity" ile duser -
  # hata mesaji sebebi soylemedigi icin bulmasi zor.
  #
  # Guncel degeri sorgulamak icin:
  #   gh api /repos/<owner>/<repo>/actions/oidc/customization/sub
  github_repo  = coalesce(var.github_repository_subject, var.github_repository)
  gha_oidc     = data.aws_iam_openid_connect_provider.github
  tf_state_arn = "arn:aws:s3:::hive-tfstate-${data.aws_caller_identity.current.account_id}"
}

data "aws_iam_policy_document" "gha_trust" {
  for_each = {
    # PR'lar ve main push'lari plan alabilir
    "hive-gha-plan" = ["repo:${local.github_repo}:pull_request", "repo:${local.github_repo}:ref:refs/heads/main"]
    # apply sadece production environment'indaki job'dan (required reviewer onayi)
    "hive-gha-apply" = ["repo:${local.github_repo}:environment:production"]
    # imaj sadece main'den
    "hive-gha-ecr" = ["repo:${local.github_repo}:ref:refs/heads/main"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.gha_oidc.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "gha" {
  for_each = data.aws_iam_policy_document.gha_trust

  name                 = each.key
  assume_role_policy   = each.value.json
  max_session_duration = 3600 * 2 # EKS + RDS degisiklikleri uzun surebilir
}

# --- plan: her seyi okuyabilir, sadece state kilidini yazabilir -------------

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.gha["hive-gha-plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.tf_state_arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.tf_state_arn}/hive/*"]
  }
  # use_lockfile: plan da kilit dosyasi yazar/siler
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.tf_state_arn}/hive/terraform.tfstate.tflock"]
  }
  # ReadOnlyAccess secret degerlerini okuyamaz; RDS master secret'ini plan'da
  # okumaya gerek yok (manage_master_user_password). Bilincli olarak eklenmedi.
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "tfstate"
  role   = aws_iam_role.gha["hive-gha-plan"].id
  policy = data.aws_iam_policy_document.plan_state.json
}

# --- apply: hackathon icin genis yetki; onay kapisinin arkasinda -------------
# Sonraki adim: AdministratorAccess yerine bu stack'in kullandigi servislere
# (ec2, eks, rds, iam:*role*, elb, ecr, route53, s3 state) daraltilmis policy.

resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.gha["hive-gha-apply"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- ecr: sadece hive reposuna push ------------------------------------------

data "aws_iam_policy_document" "ecr_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.hive.arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.gha["hive-gha-ecr"].id
  policy = data.aws_iam_policy_document.ecr_push.json
}

output "github_actions_role_arns" {
  description = "Repo variables: TF_PLAN_ROLE_ARN, TF_APPLY_ROLE_ARN, AWS_ROLE_ARN (ECR)"
  value       = { for k, r in aws_iam_role.gha : k => r.arn }
}
