output "pypi_server_urls" {
  description = "List of PyPI server URLs."
  value       = [for domain in var.dns_names : "https://${domain}.${data.aws_route53_zone.zone.name}"]
}

output "pypi_username" {
  description = "Username to access PyPI server."
  sensitive   = true
  value       = jsondecode(aws_secretsmanager_secret_version.pypiserver_secret.secret_string)["username"]
}

output "pypi_password" {
  description = "Password to access PyPI server."
  sensitive   = true
  value       = jsondecode(aws_secretsmanager_secret_version.pypiserver_secret.secret_string)["password"]
}

output "pypi_user_secret" {
  description = "AWS secret that stores PyPI username/password"
  value       = aws_secretsmanager_secret.pypiserver_secret.id
}

output "pypi_user_secret_arn" {
  description = "AWS secret ARN that stores PyPI username/password"
  value       = aws_secretsmanager_secret.pypiserver_secret.arn
}
