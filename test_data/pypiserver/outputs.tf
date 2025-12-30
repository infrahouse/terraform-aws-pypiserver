output "pypi_server_urls" {
  description = "List of PyPI server URLs."
  value       = module.pypiserver.pypi_server_urls
}

output "pypi_username" {
  description = "Username to access PyPI server."
  sensitive   = true
  value       = module.pypiserver.pypi_username
}

output "pypi_password" {
  description = "Password to access PyPI server."
  sensitive   = true
  value       = module.pypiserver.pypi_password
}

output "pypi_user_secret" {
  description = "AWS secret that stores PyPI username/password"
  value       = module.pypiserver.pypi_user_secret
}

output "asg_name" {
  description = "Name of the Auto Scaling Group for ECS container instances."
  value       = module.pypiserver.asg_name
}

output "pypi_load_balancer_arn" {
  description = "ARN of the PyPI server load balancer."
  value       = module.pypiserver.pypi_load_balancer_arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster running the PyPI server."
  value       = module.pypiserver.ecs_cluster_name
}

output "ecs_service_name" {
  description = "Name of the ECS service running the PyPI server."
  value       = module.pypiserver.ecs_service_name
}

output "capacity_info" {
  description = "Information about instance capacity and task packing."
  value       = module.pypiserver.capacity_info
}

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch dashboard for monitoring PyPI server metrics."
  value       = module.pypiserver.cloudwatch_dashboard_url
}
