output "pypi_server_urls" {
  description = "List of PyPI server URLs."
  value       = [for domain in var.dns_names : "https://${domain}.${data.aws_route53_zone.zone.name}"]
}

output "pypi_username" {
  description = "Username to access PyPI server."
  sensitive   = true
  value       = jsondecode(module.pypiserver_secret.secret_value)["username"]
}

output "pypi_password" {
  description = "Password to access PyPI server."
  sensitive   = true
  value       = jsondecode(module.pypiserver_secret.secret_value)["password"]
}

output "pypi_user_secret" {
  description = "AWS secret that stores PyPI username/password"
  value       = module.pypiserver_secret.secret_id
}

output "pypi_user_secret_arn" {
  description = "AWS secret ARN that stores PyPI username/password"
  value       = module.pypiserver_secret.secret_arn
}

output "pypi_load_balancer_arn" {
  description = "ARN of the PyPI server load balancer."
  value       = module.pypiserver.load_balancer_arn
}

output "ecs_service_arn" {
  description = "ARN of the ECS service running the PyPI server."
  value       = module.pypiserver.service_arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster running the PyPI server."
  value       = module.pypiserver.cluster_name
}

output "ecs_service_name" {
  description = "Name of the ECS service running the PyPI server."
  value       = module.pypiserver.service_name
}

output "asg_name" {
  description = "Name of the Auto Scaling Group for ECS container instances."
  value       = module.pypiserver.asg_name
}

output "cloudwatch_alarm_sns_topic_arn" {
  description = "ARN of the SNS topic used for CloudWatch alarm notifications."
  value       = aws_sns_topic.alarms.arn
}

output "cloudwatch_alarm_arns" {
  description = "ARNs of CloudWatch alarms created for EFS monitoring."
  value = {
    efs_burst_credits = var.efs_throughput_mode == "bursting" ? (
      aws_cloudwatch_metric_alarm.efs_burst_credit_balance[0].arn
    ) : null
    efs_throughput_high = aws_cloudwatch_metric_alarm.efs_throughput_utilization.arn
  }
}

output "task_min_count" {
  description = "Actual task_min_count used (auto-calculated if var.task_min_count is null)."
  value       = local.task_min_count
}

output "capacity_info" {
  description = "Information about instance capacity and task packing."
  value = {
    instance_type                    = var.asg_instance_type
    instance_vcpu_count              = local.instance_vcpu_count
    instance_ram_mb                  = local.instance_total_ram_mb
    system_overhead_mb               = local.total_overhead_mb
    available_ram_mb_per_instance    = local.available_ram_mb
    available_cpu_units_per_instance = local.available_cpu_units
    container_memory_mb              = var.container_memory
    container_memory_reservation_mb  = local.container_memory_reservation_actual
    container_cpu_units              = local.container_cpu
    tasks_per_instance_ram_limit     = local.tasks_per_instance_ram
    tasks_per_instance_cpu_limit     = local.tasks_per_instance_cpu
    tasks_per_instance               = local.tasks_per_instance
    limiting_factor                  = local.tasks_per_instance_ram < local.tasks_per_instance_cpu ? "RAM" : "CPU"
    asg_instance_count               = local.asg_instance_count
    auto_calculated_task_min_count   = local.auto_task_min_count
    actual_task_min_count            = local.task_min_count
    actual_task_max_count            = local.task_max_count
    gunicorn_workers_per_container   = local.gunicorn_workers
  }
}

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch dashboard for monitoring PyPI server metrics."
  value = var.enable_cloudwatch_dashboard ? (
    "https://console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.pypiserver[0].dashboard_name}"
  ) : null
}
