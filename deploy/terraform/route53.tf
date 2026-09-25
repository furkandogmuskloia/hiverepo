################################################################################
# chem.kloia.me - cutover kaydi
#
# Onemli: kloia.me Cloudflare'da, ama chem alt alani NS ile Route53'e
# DEVREDILMIS (zone Z07389103CL53BOHXGNNK). Yani kayit Cloudflare'dan degil
# buradan yonetiliyor.
#
# chem.kloia.me kendi zone'unun APEX'i oldugu icin CNAME yazilamaz;
# ALB'yi gostermek ancak Route53 ALIAS ile mumkun.
#
# Cutover tek degiskenle yapilir:
#   terraform apply -var cutover_to_eks=true
# Geri alma ayni sekilde false. TTL zaten 60sn, yayilma ~1 dakika.
################################################################################

data "aws_route53_zone" "chem" {
  count = var.manage_dns ? 1 : 0

  name         = "chem.kloia.me."
  private_zone = false
}

# ALB'yi Terraform degil, Ingress uzerinden AWS Load Balancer Controller
# olusturuyor. Cutover aninda etiketlerinden bulunur.
data "aws_lb" "hive" {
  count = var.manage_dns && var.cutover_to_eks ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = local.name
    "ingress.k8s.aws/stack" = "hive/hive"
  }
}

# Tek kaynak, iki durum. Ayri kaynaklar kullanilsaydi gecis sirasinda
# Route53'te ya cift kayit ya da bosluk olusabilirdi; boylece UPSERT ile
# yerinde degisiyor.
resource "aws_route53_record" "chem" {
  # Varsayilan KAPALI. Acmadan once mevcut kayit import edilmeli:
  #   terraform import aws_route53_record.chem[0] \
  #     Z07389103CL53BOHXGNNK_chem.kloia.me_A
  # Import edilmeden apply edilirse canli kayit uzerine yazilir.
  count = var.manage_dns ? 1 : 0

  zone_id         = data.aws_route53_zone.chem[0].zone_id
  name            = "chem.kloia.me"
  type            = "A"
  allow_overwrite = true

  # cutover_to_eks = false -> eski EC2'ye duz A kaydi
  ttl     = var.cutover_to_eks ? null : var.legacy_ttl
  records = var.cutover_to_eks ? null : [var.legacy_ip]

  # cutover_to_eks = true -> ALB'ye ALIAS
  dynamic "alias" {
    for_each = var.cutover_to_eks ? [1] : []
    content {
      name                   = data.aws_lb.hive[0].dns_name
      zone_id                = data.aws_lb.hive[0].zone_id
      evaluate_target_health = true
    }
  }
}
