resource "aws_ecr_repository" "hive" {
  name = local.name

  # ayni etiketin uzerine yazilmasini engeller - hangi imajin kostugu kesin olur
  image_tag_mutability = "IMMUTABLE"

  # hackathon: destroy'da repo imajlarla birlikte silinsin
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "hive" {
  repository = aws_ecr_repository.hive.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "son 10 imaj tutulur"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
