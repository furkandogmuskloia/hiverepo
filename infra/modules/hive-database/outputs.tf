output "db_instance_address" {
  description = "RDS endpoint hostname"
  value       = module.db.db_instance_address
}

output "db_instance_identifier" {
  description = "RDS instance identifier"
  value       = module.db.db_instance_identifier
}

output "security_group_id" {
  description = "Security group attached to the database"
  value       = aws_security_group.db.id
}

output "app_secret_arn" {
  description = "Secrets Manager secret holding the application's DB connection"
  value       = aws_secretsmanager_secret.app.arn
}

output "app_secret_name" {
  description = "Secrets Manager secret name referenced by the ExternalSecret"
  value       = aws_secretsmanager_secret.app.name
}
