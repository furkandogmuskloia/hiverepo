################################################################################
# RDS Postgres - sunucudaki yerel postgresql.service'in yerini aliyor
################################################################################

# Kasitli olarak EKS node security group'una referans VERMIYORUZ.
# Verseydik RDS, EKS bitene kadar beklerdi ve apply serilesirdi.
# Private subnet CIDR'lari ile RDS ve EKS paralel kurulur (~8 dk kazanc).
# Bu subnetlerde node'lar disinda bir sey yok ve disariya yol yok.
resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds-"
  description = "HIVE Postgres - sadece private subnetlerden 5432"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "EKS node private subnetleri"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  # egress tanimlanmadi -> RDS disariya baglanti acamaz (acmasi da gerekmiyor)

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.0"

  identifier = "${local.name}-pg"

  engine               = "postgres"
  engine_version       = "16"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = var.db_instance_class # Graviton, en ucuz sinif

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "hive"
  username = "hive"
  port     = 5432

  # Sifre Terraform degiskeninde tutulmuyor: RDS uretip Secrets Manager'a
  # yaziyor ve rotasyonu AWS yonetiyor. Deploy script'i oradan okuyor.
  manage_master_user_password = true

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = module.vpc.database_subnet_group
  create_db_subnet_group = false
  publicly_accessible    = false

  # HA: AWS baska bir AZ'de senkron standby tutar, arizada otomatik failover
  # yapar. Acilmasi online bir islem - kesinti yok. Instance ucreti ~2 katina
  # cikiyor (db.t4g.micro icin ~13 -> 26 USD/ay).
  multi_az = true

  # Modulun varsayilani false. O haliyle multi_az gibi degisiklikler bakim
  # penceresine (tue 23:11 UTC) kuyruklaniyor ve terraform apply exit 0
  # verdigi icin uygulanmis gibi gorunuyor - sessizce kaciyor.
  apply_immediately = true

  # hackathon ayari - prod'da deletion_protection=true olmali
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  create_monitoring_role       = false
  performance_insights_enabled = false
  create_cloudwatch_log_group  = false

  # TLS'i veritabani seviyesinde zorunlu kil. Uygulama DB_SSLMODE=require ile
  # baglaniyor; bu parametre sifresiz baglantilari RDS tarafinda reddediyor.
  parameters = [
    {
      name         = "rds.force_ssl"
      value        = "1"
      apply_method = "pending-reboot"
    }
  ]

  tags = local.tags
}
