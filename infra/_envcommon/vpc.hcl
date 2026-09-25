terraform {
  source = "tfr:///terraform-aws-modules/vpc/aws?version=6.7.3"
}

locals {
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  prefix           = local.environment_vars.inputs.prefix
  cidr             = local.region_vars.inputs.vpc_cidr_block
  azs              = local.region_vars.inputs.azs

  // Tüm subnet'ler tek bloktan türetilir; elle CIDR yazılmaz.
  //   public   /24  x3  ALB, NAT
  //   private  /20  x3  EKS node + pod (VPC CNI her pod'a VPC IP'si verir)
  //   database /24  x3  RDS
  public_subnets   = [for i, _ in local.azs : cidrsubnet(local.cidr, 8, i)]
  private_subnets  = [for i, _ in local.azs : cidrsubnet(local.cidr, 4, i + 1)]
  database_subnets = [for i, _ in local.azs : cidrsubnet(local.cidr, 8, 100 + i)]
}

inputs = {
  name = format("%s-vpc", local.prefix)
  cidr = local.cidr
  azs  = local.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  create_database_subnet_group = true

  enable_nat_gateway = true
  // Maliyet tercihi: tek NAT. Bir AZ kaybında node'ların dışarı çıkışı gider;
  // gelen trafik (ALB) ve RDS etkilenmez. Üretimde one_nat_gateway_per_az = true.
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  // AWS Load Balancer Controller subnet keşfi
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}
