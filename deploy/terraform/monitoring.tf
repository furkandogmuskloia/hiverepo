################################################################################
# Alarmlar - semptoma gore (kullanicinin gordugu), sebebe gore degil.
#
# ALB'yi Terraform degil AWS Load Balancer Controller olusturuyor (Ingress'ten).
# Adi sabit degil; controller'in koydugu tag'lerle bulunuyor. Ingress'e sabit
# isim vermek ALB'yi yeniden yaratir (yeni DNS) - bu yuzden tag ile lookup.
# Not: ALB yoksa (Ingress silinmisse) plan bu data source'ta hata verir.
# route53.tf'teki data.aws_lb.hive cutover bayragina bagli (count); alarmlar hep acik.
################################################################################

locals {
  runbook_url = "https://github.com/furkandogmuskloia/hiverepo/blob/main/README.md#deploy-runbook"
  alb_tags = {
    "elbv2.k8s.aws/cluster" = local.name
    "ingress.k8s.aws/stack" = "hive/hive"
  }
}

data "aws_lb" "hive_alarms" {
  tags = merge(local.alb_tags, { "ingress.k8s.aws/resource" = "LoadBalancer" })
}

data "aws_lb_target_group" "hive" {
  tags = merge(local.alb_tags, { "ingress.k8s.aws/resource" = "hive/hive-hive:80" })
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"

  # Alarm bildirimleri kaynak adlari, metrik esikleri ve zamanlama iceriyor -
  # bir saldirgan icin degerli kesif bilgisi. AWS yonetimli anahtar yeterli
  # ve ucretsiz; CMK'ya gecmek istenirse tek satir degisiyor.
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- ALB: kullanicinin gordugu --------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${local.name}-alb-5xx-rate"
  alarm_description   = "HIVE isteklerinin %1'inden fazlasi 5xx donuyor (2 dk). Runbook: ${local.runbook_url}"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * (FILL(t5xx, 0) + FILL(e5xx, 0)) / IF(req > 0, req, 1)"
    label       = "5xx %"
    return_data = true
  }

  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = data.aws_lb.hive_alarms.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "t5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = data.aws_lb.hive_alarms.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "e5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = data.aws_lb.hive_alarms.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_no_healthy_targets" {
  alarm_name          = "${local.name}-alb-no-healthy-targets"
  alarm_description   = "ALB arkasinda saglikli HIVE pod'u yok - servis tamamen erisilemez. Runbook: ${local.runbook_url}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching" # metrik hic gelmiyorsa da alarm
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = data.aws_lb.hive_alarms.arn_suffix
    TargetGroup  = data.aws_lb_target_group.hive.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_latency_p95" {
  alarm_name          = "${local.name}-alb-latency-p95"
  alarm_description   = "HIVE yanit suresi p95 > 500 ms (5 dk). Runbook: ${local.runbook_url}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = data.aws_lb.hive_alarms.arn_suffix
  }
}

# --- RDS ------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu"
  alarm_description   = "hive-pg CPU > %80 (5 dk). Runbook: ${local.runbook_url}"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = module.rds.db_instance_identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${local.name}-rds-free-storage"
  alarm_description   = "hive-pg bos disk < 2 GiB. Runbook: ${local.runbook_url}"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = module.rds.db_instance_identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${local.name}-rds-connections"
  alarm_description   = "hive-pg baglanti sayisi > 80 (db.t4g.micro limiti ~112). Runbook: ${local.runbook_url}"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = module.rds.db_instance_identifier }
}

# Yedek/ariza/failover olaylari: "yedek basarisiz oldu" artik kimsenin
# fark etmedigi bir sey olmasin (eski ortamda 6 ay fark edilmedi).
resource "aws_db_event_subscription" "rds" {
  name             = "${local.name}-rds-events"
  sns_topic        = aws_sns_topic.alerts.arn
  source_type      = "db-instance"
  source_ids       = [module.rds.db_instance_identifier]
  event_categories = ["availability", "backup", "failover", "failure", "low storage", "recovery"]
}
