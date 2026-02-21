# Examples

## Basic Deployment

The simplest deployment with only required variables. Uses defaults for everything
else: `t3.small` instances, elastic EFS throughput, daily backups.

```hcl
module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.1.0"

  providers = {
    aws     = aws
    aws.dns = aws
  }

  asg_subnets           = ["subnet-aaa", "subnet-bbb"]
  load_balancer_subnets = ["subnet-ccc", "subnet-ddd"]
  zone_id               = "Z1234567890ABC"
  alarm_emails          = ["ops@example.com"]
}

output "pypi_url" {
  value = module.pypiserver.pypi_server_urls[0]
}

output "pypi_username" {
  value     = module.pypiserver.pypi_username
  sensitive = true
}

output "pypi_password" {
  value     = module.pypiserver.pypi_password
  sensitive = true
}
```

## Production Deployment

Production-ready configuration with larger instances, pinned image version,
longer backup retention, and multiple DNS names.

```hcl
module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.1.0"

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  # Required
  asg_subnets           = data.aws_subnets.private.ids
  load_balancer_subnets = data.aws_subnets.public.ids
  zone_id               = data.aws_route53_zone.main.zone_id
  alarm_emails          = ["ops@example.com", "oncall@example.com"]

  # Naming
  service_name = "pypi"
  dns_names    = ["pypi", "packages"]
  environment  = "production"

  # Scaling
  asg_instance_type = "c6a.xlarge"
  task_min_count    = 6
  task_max_count    = 12

  # Container
  docker_image_tag = "v2.3.0"

  # Backups
  enable_efs_backup     = true
  backup_retention_days = 30
  backup_schedule       = "cron(0 3 * * ? *)"

  # Cost optimization
  efs_lifecycle_policy = 30

  # Alerting
  alarm_topic_arns = [aws_sns_topic.pagerduty.arn]
}
```

## Cost-Optimized (Dev/Test)

Minimal configuration for development or testing. Disables backups and uses
small instances.

```hcl
module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.1.0"

  providers = {
    aws     = aws
    aws.dns = aws
  }

  asg_subnets           = [data.aws_subnets.private.ids[0]]
  load_balancer_subnets = data.aws_subnets.public.ids
  zone_id               = data.aws_route53_zone.dev.zone_id
  alarm_emails          = ["dev@example.com"]

  # Minimal resources
  asg_instance_type = "t3.micro"
  container_memory  = 256

  # Disable backups for dev
  enable_efs_backup = false

  # Allow clean teardown
  access_log_force_destroy = true
  backups_force_destroy    = true

  environment = "development"
}
```

## Cross-Account DNS

When your Route53 zone is in a different AWS account (common with centralized
DNS management).

```hcl
provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "dns"
  region = "us-east-1"

  assume_role {
    role_arn = "arn:aws:iam::DNS_ACCOUNT_ID:role/dns-admin"
  }
}

module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.1.0"

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  asg_subnets           = data.aws_subnets.private.ids
  load_balancer_subnets = data.aws_subnets.public.ids
  zone_id               = "Z0987654321XYZ"
  alarm_emails          = ["ops@example.com"]
}
```

## Working Example

A complete working example is available in the repository:
[`examples/basic/`](https://github.com/infrahouse/terraform-aws-pypiserver/tree/main/examples/basic)
