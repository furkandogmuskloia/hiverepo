terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7"
    }
  }
}

# Şifre ephemeral üretilir ve RDS'e / Secrets Manager'a write-only alanlarla yazılır:
# Terraform state'ine hiçbir zaman girmez. Rotasyon: password_version'ı artır.
ephemeral "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%^*-_=+"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "PostgreSQL access for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.2"

  identifier = "${var.name}-db"

  engine               = "postgres"
  engine_version       = var.engine_version
  family               = "postgres${var.major_engine_version}"
  major_engine_version = var.major_engine_version
  instance_class       = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.username
  port     = 5432

  manage_master_user_password = false
  password_wo                 = ephemeral.random_password.db.result
  password_wo_version         = var.password_version

  multi_az               = var.multi_az
  create_db_subnet_group = false
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = 7
  backup_window           = "02:00-03:00"
  maintenance_window      = "Sun:03:30-Sun:04:30"
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = false
  copy_tags_to_snapshot   = true

  performance_insights_enabled = true
  apply_immediately            = true

  parameters = [
    # Geri dönüş yolu: RDS'i yayıncı yapıp eski DB'ye ters replikasyon kurulabilsin.
    { name = "rds.logical_replication", value = "1", apply_method = "pending-reboot" },
    { name = "rds.force_ssl", value = "1", apply_method = "pending-reboot" },
    { name = "log_min_duration_statement", value = "500" },
  ]

  tags = var.tags
}

# Uygulamanın ihtiyaç duyduğu her şey tek, isimle bulunabilen bir secret'ta.
# External Secrets bunu okuyup pod'a Kubernetes Secret olarak verir.
resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name}/db"
  description             = "HIVE application database connection"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string_wo = jsonencode({
    DB_HOST     = module.db.db_instance_address
    DB_PORT     = "5432"
    DB_NAME     = var.db_name
    DB_USER     = var.username
    DB_PASSWORD = ephemeral.random_password.db.result
    DB_SSLMODE  = "require"
  })
  secret_string_wo_version = var.password_version
}
