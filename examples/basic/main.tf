# Basic PyPI Server Example
#
# This example shows the simplest deployment: a private PyPI server
# with default settings (t3.small instances, elastic EFS, daily backups).
#
# Usage:
#   1. Update subnet IDs to match your VPC
#   2. Update zone_id to your Route53 hosted zone
#   3. Update alarm_emails to your email address
#   4. Run: terraform init && terraform apply

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.11, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# Look up your existing Route 53 hosted zone
data "aws_route53_zone" "main" {
  name = "example.com" # Replace with your domain
}

# Look up subnets by tags (adjust filters for your VPC)
data "aws_subnets" "private" {
  filter {
    name   = "tag:Type"
    values = ["private"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "tag:Type"
    values = ["public"]
  }
}

# Deploy PyPI server
module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.2.0"

  # Both providers point to the same account in this example.
  # Use a separate aws.dns provider if Route53 is in another account.
  providers = {
    aws     = aws
    aws.dns = aws
  }

  asg_subnets           = data.aws_subnets.private.ids
  load_balancer_subnets = data.aws_subnets.public.ids
  zone_id               = data.aws_route53_zone.main.zone_id
  alarm_emails          = ["ops@example.com"] # Replace with your email
}

# Outputs

output "pypi_url" {
  description = "URL of the PyPI server"
  value       = module.pypiserver.pypi_server_urls[0]
}

output "pypi_username" {
  description = "Username for PyPI authentication"
  value       = module.pypiserver.pypi_username
  sensitive   = true
}

output "pypi_password" {
  description = "Password for PyPI authentication"
  value       = module.pypiserver.pypi_password
  sensitive   = true
}
