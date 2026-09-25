################################################################################
# DB erisim bastion'i - SSM Session Manager ile
#
# RDS private; dump/inceleme icin laptop'tan erisim bu makine uzerinden
# port-forward ile yapilir. SSH YOK: public IP yok, inbound kural yok, anahtar
# yok (eski sunucuda sizan SSH anahtari tam da bu yuzden bir bulguydu). Erisim
# IAM ile verilir ve her oturum CloudTrail'e yazilir.
#
#   aws ssm start-session --target <instance-id> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters host=<rds-endpoint>,portNumber=5432,localPortNumber=5433
#
# Kullanilmadiginda kapatmak icin: enable_bastion = false (maliyet ~3 USD/ay).
################################################################################

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_iam_policy_document" "bastion_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name               = "${local.name}-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
  tags               = local.tags
}

# Sadece SSM ajani icin gereken yetki. Eski sunucudaki gibi AdministratorAccess YOK.
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count = var.enable_bastion ? 1 : 0

  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name = "${local.name}-bastion"
  role = aws_iam_role.bastion[0].name
  tags = local.tags
}

resource "aws_security_group" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name_prefix = "${local.name}-bastion-"
  description = "SSM bastion - inbound yok; cikis SSM (443) ve RDS (5432)"
  vpc_id      = module.vpc.vpc_id
  tags        = merge(local.tags, { Name = "${local.name}-bastion" })

  lifecycle {
    create_before_destroy = true
  }
}

# SSM ajani AWS API'lerine NAT uzerinden 443 ile gider (paket kurulumu da).
resource "aws_vpc_security_group_egress_rule" "bastion_https" {
  count = var.enable_bastion ? 1 : 0

  security_group_id = aws_security_group.bastion[0].id
  description       = "SSM ve paket depolari"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "bastion_postgres" {
  count = var.enable_bastion ? 1 : 0

  security_group_id            = aws_security_group.bastion[0].id
  description                  = "RDS PostgreSQL"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# RDS SG private subnet CIDR'larina zaten acik; bastion private subnet'te oldugu
# icin RDS tarafinda yeni kural gerekmez.
resource "aws_instance" "bastion" {
  count = var.enable_bastion ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = "t4g.nano"
  subnet_id                   = module.vpc.private_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  associate_public_ip_address = false

  metadata_options {
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Makinenin uzerinde de dump alinabilsin (buyuk DB'lerde laptop'a akitmaktan hizli).
  user_data = <<-EOT
    #!/bin/bash
    dnf install -y postgresql16
  EOT

  tags = merge(local.tags, { Name = "${local.name}-bastion", Role = "db-access" })

  lifecycle {
    # Yeni AMI yayinlandiginda bastion'i yeniden yaratma; guncelleme bilincli yapilsin.
    ignore_changes = [ami, user_data]
  }
}

output "bastion_instance_id" {
  description = "SSM ile baglanilacak bastion"
  value       = try(aws_instance.bastion[0].id, null)
}

output "db_port_forward_command" {
  description = "RDS'i laptop'ta localhost:5433'e getirir (session-manager-plugin gerekir)"
  value = try(format(
    "aws ssm start-session --region %s --target %s --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=%s,portNumber=5432,localPortNumber=5433",
    var.region, aws_instance.bastion[0].id, module.rds.db_instance_address
  ), null)
}
