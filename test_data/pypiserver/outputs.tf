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
