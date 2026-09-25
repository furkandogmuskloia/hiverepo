variable "name" {
  description = "Resource name prefix, e.g. chem-hive"
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in"
  type        = string
}

variable "db_subnet_group_name" {
  description = "Existing DB subnet group (created by the VPC module)"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDRs allowed to reach PostgreSQL (EKS private subnets)"
  type        = list(string)
}

variable "engine_version" {
  description = "PostgreSQL engine version; keep the source major version for a clean migration"
  type        = string
  default     = "15"
}

variable "major_engine_version" {
  description = "PostgreSQL major version, used for the parameter group family"
  type        = string
  default     = "15"
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "allocated_storage" {
  description = "Initial storage in GiB; autoscaling allows up to 5x"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ; automatic failover"
  type        = bool
  default     = true
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "hive"
}

variable "username" {
  description = "Master username; the application currently connects as this user"
  type        = string
  default     = "hive"
}

variable "password_version" {
  description = "Bump to rotate the master password (write-only, never stored in state)"
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Block accidental deletion of the instance"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
