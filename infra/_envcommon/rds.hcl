terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}//modules/hive-database"
}

locals {
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  prefix           = local.environment_vars.inputs.prefix
}

inputs = {
  name = local.prefix

  // Kaynak DB PostgreSQL 15.19; aynı ana sürüm, dump/replikasyon uyumlu.
  engine_version       = "15"
  major_engine_version = "15"
  instance_class       = "db.t4g.medium"
  allocated_storage    = 20

  // Veri kaybı olmasın şartı: senkron standby + otomatik failover, 7 gün PITR.
  multi_az            = true
  deletion_protection = true

  tags = local.environment_vars.inputs.tags
}
