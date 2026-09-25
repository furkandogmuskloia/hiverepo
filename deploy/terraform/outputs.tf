output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "kubeconfig'i yazmak icin calistir"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile ${var.aws_profile}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.hive.repository_url
}

output "vpc_cidr_block" {
  description = "NetworkPolicy sablonuna islenir"
  value       = module.vpc.vpc_cidr_block
}

output "db_host" {
  value = module.rds.db_instance_address
}

output "db_port" {
  value = module.rds.db_instance_port
}

output "db_name" {
  value = "hive"
}

output "db_username" {
  # module.rds.db_instance_username sensitive isaretli; deger zaten
  # rds.tf'te bizim verdigimiz sabit, dogrudan yaziliyor.
  value = "hive"
}

output "db_master_user_secret_arn" {
  description = "RDS sifresinin durdugu Secrets Manager kaydi - deploy.sh buradan okur"
  value       = module.rds.db_instance_master_user_secret_arn
  sensitive   = true
}

output "capacity_mix" {
  description = "Steady-state node dagilimi (spot oncelikli, ondemand tabanli)"
  value = format("ondemand %d-%d / spot %d-%d",
    var.node_ondemand_min_size, var.node_ondemand_max_size,
    var.node_spot_min_size, var.node_spot_max_size,
  )
}
