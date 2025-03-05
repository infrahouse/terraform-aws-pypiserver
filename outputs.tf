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
