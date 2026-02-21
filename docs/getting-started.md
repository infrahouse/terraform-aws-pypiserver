# Getting Started

## Prerequisites

Before deploying the module you need:

1. **VPC** with `enable_dns_hostnames = true` and `enable_dns_support = true`
2. **At least 2 public subnets** in different availability zones (for the ALB)
3. **At least 1 private subnet** (for ECS instances)
4. **Route53 hosted zone** for DNS records and certificate validation
5. **Internet Gateway** attached to the VPC

## Provider Configuration

The module requires two AWS provider configurations. The main provider manages all
resources; the `aws.dns` provider manages Route53 records (useful when DNS is in a
different AWS account).

```hcl
# If DNS is in the same account, pass the same provider twice:
provider "aws" {
  region = "us-west-2"
}

module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.1.0"

  providers = {
    aws     = aws
    aws.dns = aws  # Same account
  }

  # ...
}
```

```hcl
# If DNS is in a different account:
provider "aws" {
  alias  = "dns"
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::ACCOUNT_ID:role/dns-admin"
  }
}

module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.1.0"

  providers = {
    aws     = aws
    aws.dns = aws.dns  # Different account
  }

  # ...
}
```

## Minimal Deployment

```hcl
module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/pypiserver/aws"
  version = "2.1.0"

  providers = {
    aws     = aws
    aws.dns = aws
  }

  # Required variables
  asg_subnets           = ["subnet-private-1a", "subnet-private-1b"]
  load_balancer_subnets = ["subnet-public-1a", "subnet-public-1b"]
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

Run:

```bash
terraform init
terraform apply
```

The module creates DNS records, provisions an ACM certificate, and deploys the
ECS service. First deployment takes 5-10 minutes while the certificate validates
and ECS tasks start.

## Retrieve Credentials

The module auto-generates credentials and stores them in AWS Secrets Manager.

```bash
# From Terraform outputs
terraform output -raw pypi_username
terraform output -raw pypi_password

# Or directly from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id PYPISERVER_SECRET-xxxxx \
  --query SecretString --output text | jq -r '.username, .password'
```

## Configure pip

Add to `~/.pip/pip.conf` (Linux/macOS) or `%APPDATA%\pip\pip.ini` (Windows):

```ini
[global]
extra-index-url = https://USERNAME:PASSWORD@pypiserver.example.com/simple/
trusted-host = pypiserver.example.com
```

Or use an environment variable:

```bash
export PIP_EXTRA_INDEX_URL="https://USERNAME:PASSWORD@pypiserver.example.com/simple/"
```

## Configure twine for Uploads

Add to `~/.pypirc`:

```ini
[distutils]
index-servers =
    private

[private]
repository = https://pypiserver.example.com/
username = USERNAME
password = PASSWORD
```

Upload packages:

```bash
twine upload --repository private dist/*
```

## Next Steps

- [Configuration](configuration.md) -- Tune instance types, container resources, and EFS settings
- [Sizing](SIZING.md) -- Capacity planning for your workload
- [Architecture](architecture.md) -- Understand how the components interact
