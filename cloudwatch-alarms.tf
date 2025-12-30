# SNS Topic for CloudWatch Alarms
resource "aws_sns_topic" "alarms" {
  name         = "${var.service_name}-cloudwatch-alarms"
  display_name = "CloudWatch Alarms for ${var.service_name}"

  tags = merge(
    {
      Name = "${var.service_name}-cloudwatch-alarms"
    },
    local.default_module_tags
  )
}

# Email Subscriptions for CloudWatch Alarms
# AWS will send confirmation emails to each address
resource "aws_sns_topic_subscription" "alarm_emails" {
  for_each  = toset(var.alarm_emails)
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

# Local value combining created SNS topic with additional topic ARNs
locals {
  all_alarm_topic_arns = concat(
    [aws_sns_topic.alarms.arn],
    var.alarm_topic_arns
  )
}

# EFS Burst Credit Balance Alarm
# Low burst credits can impact EFS performance during high I/O operations
resource "aws_cloudwatch_metric_alarm" "efs_burst_credit_balance" {
  alarm_name          = "${var.service_name}-efs-burst-credits-low"
  alarm_description   = "EFS burst credit balance is below threshold. This may impact I/O performance."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "BurstCreditBalance"
  namespace           = "AWS/EFS"
  period              = 300 # 5 minutes
  statistic           = "Average"
  threshold           = var.efs_burst_credit_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    FileSystemId = aws_efs_file_system.packages-enc.id
  }

  alarm_actions = local.all_alarm_topic_arns
  ok_actions    = local.all_alarm_topic_arns

  tags = merge(
    {
      Name = "${var.service_name}-efs-burst-credits-alarm"
    },
    local.default_module_tags
  )
}

# EFS Throughput Utilization Alarm
# High throughput utilization may indicate approaching performance limits
resource "aws_cloudwatch_metric_alarm" "efs_throughput_utilization" {
  alarm_name          = "${var.service_name}-efs-throughput-high"
  alarm_description   = "EFS throughput utilization is above 80%. May be approaching performance limits."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "PercentIOLimit"
  namespace           = "AWS/EFS"
  period              = 300 # 5 minutes
  statistic           = "Average"
  threshold           = 80 # percent
  treat_missing_data  = "notBreaching"

  dimensions = {
    FileSystemId = aws_efs_file_system.packages-enc.id
  }

  alarm_actions = local.all_alarm_topic_arns
  ok_actions    = local.all_alarm_topic_arns

  tags = merge(
    {
      Name = "${var.service_name}-efs-throughput-alarm"
    },
    local.default_module_tags
  )
}