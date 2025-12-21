# terraform-aws-pypiserver

A production-ready Terraform module for deploying a private [PyPI server](https://github.com/pypiserver/pypiserver) 
on AWS with high availability, encryption, automated backups, and monitoring.

## Architecture

```
                                    ┌─────────────────────────────────────────────────────────────┐
                                    │                         AWS Cloud                           │
                                    │                                                             │
┌──────────┐   HTTPS    ┌───────────────────────┐                                                 │
│   pip    │───────────▶│  Application Load     │                                                 │
│  twine   │            │     Balancer          │                                                 │
└──────────┘            │  (Public Subnets)     │                                                 │
                        └───────────┬───────────┘                                                 │
                                    │                                                             │
                        ┌───────────▼───────────┐     ┌─────────────────────┐                     │
                        │   ECS Cluster         │     │   AWS Secrets       │                     │
                        │   (Auto Scaling)      │────▶│   Manager           │                     │
                        │                       │     │   (Credentials)     │                     │
                        │  ┌─────┐    ┌─────┐   │     └─────────────────────┘                     │
                        │  │Task │    │Task │   │                                                 │
                        │  │ 1   │    │ 2   │   │     ┌─────────────────────┐                     │
                        │  └──┬──┘    └──┬──┘   │     │   CloudWatch        │                     │
                        │     │          │      │────▶│   Logs + Alarms     │                     │
                        │  (Private Subnets)    │     └─────────────────────┘                     │
                        └─────────┬─────────────┘                                                 │
                                  │ NFS                                                           │
                        ┌─────────▼─────────────┐     ┌─────────────────────┐                     │
                        │   EFS (Encrypted)     │────▶│   AWS Backup        │                     │
                        │   Package Storage     │     │   (Daily Backups)   │                     │
                        └───────────────────────┘     └─────────────────────┘                     │
                                                                                                  │
                        ┌───────────────────────┐                                                 │
                        │   Route53             │                                                 │
                        │   DNS Records         │                                                 │
                        └───────────────────────┘                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Features

- **High Availability**: Auto-scaling ECS cluster across multiple availability zones
- **Encryption at Rest**: EFS storage encrypted with AWS KMS
- **Encryption in Transit**: HTTPS with auto-provisioned ACM certificates
- **Authentication**: HTTP Basic Auth with credentials stored in AWS Secrets Manager
- **Automated Backups**: Configurable AWS Backup for EFS with retention policies
- **Monitoring**: CloudWatch alarms for EFS performance (burst credits, throughput)
- **Cost Optimization**: EFS lifecycle policies to move old packages to Infrequent Access storage
- **Consistent Package Listings**: Uses `--backend simple-dir` to prevent cache synchronization issues across distributed containers

## Prerequisites

- VPC with `enable_dns_hostnames = true` and `enable_dns_support = true`
- At least 2 public subnets (for ALB) in different availability zones
- At least 1 private subnet (for ECS instances)
- Route53 hosted zone for DNS records
- Internet Gateway attached to VPC

## Usage

### Basic Example

```hcl
module "pypiserver" {
  source  = "infrahouse/pypiserver/aws"
  version = "2.0.1"

  providers = {
    aws     = aws
    aws.dns = aws
  }

  # Required
  asg_subnets           = ["subnet-private-1a", "subnet-private-1b"]
  load_balancer_subnets = ["subnet-public-1a", "subnet-public-1b"]
  zone_id               = "Z1234567890ABC"
  alarm_emails          = ["ops@example.com"]
}

# Retrieve credentials
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

### Production Example

```hcl
module "pypiserver" {
  source  = "infrahouse/pypiserver/aws"
  version = "~> 2.1"

  providers = {
    aws     = aws
    aws.dns = aws.dns  # Can use different provider for DNS
  }

  # Required
  asg_subnets           = data.aws_subnets.private.ids
  load_balancer_subnets = data.aws_subnets.public.ids
  zone_id               = data.aws_route53_zone.main.zone_id
  alarm_emails          = ["ops@example.com", "oncall@example.com"]

  # Naming
  service_name = "pypi"
  dns_names    = ["pypi", "packages"]  # Creates pypi.example.com, packages.example.com
  environment  = "production"

  # Scaling - control via task counts; ASG size is auto-calculated
  asg_instance_type = "t3.small"
  task_min_count    = 2
  task_max_count    = 10
  # asg_min_size    = 2   # Optional: override only if needed
  # asg_max_size    = 6   # Optional: override only if needed

  # Container
  docker_image_tag = "v2.3.0"  # Pin to specific version

  # Backups
  enable_efs_backup     = true
  backup_retention_days = 30
  backup_schedule       = "cron(0 3 * * ? *)"  # 3 AM UTC daily

  # Cost optimization
  efs_lifecycle_policy = 30  # Move to IA after 30 days

  # Additional alerting
  alarm_topic_arns = [aws_sns_topic.pagerduty.arn]

  # SSH access for debugging (optional)
  users = [
    {
      name   = "admin"
      groups = "wheel"
      sudo   = ["ALL=(ALL) NOPASSWD:ALL"]
      ssh_authorized_keys = [
        "ssh-rsa AAAA... admin@example.com"
      ]
    }
  ]
}
```

## Uploading and Installing Packages

### Configure pip

Add to `~/.pip/pip.conf` (Linux/macOS) or `%APPDATA%\pip\pip.ini` (Windows):

```ini
[global]
extra-index-url = https://USERNAME:PASSWORD@pypi.example.com/simple/
trusted-host = pypi.example.com
```

Or use environment variables:

```bash
export PIP_EXTRA_INDEX_URL="https://USERNAME:PASSWORD@pypi.example.com/simple/"
```

### Configure twine for uploads

Add to `~/.pypirc`:

```ini
[distutils]
index-servers =
    private

[private]
repository = https://pypi.example.com/
username = USERNAME
password = PASSWORD
```

Upload packages:

```bash
twine upload --repository private dist/*
```

### Retrieve Credentials

```bash
# Get credentials from Terraform outputs
terraform output -raw pypi_username
terraform output -raw pypi_password

# Or from AWS Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id PYPISERVER_SECRET-xxxxx \
  --query SecretString --output text | jq -r '.username, .password'
```

## Security Considerations

- **Network**: ALB can be deployed in public subnets (internet-facing) or private subnets (internal-only)
- **Authentication**: HTTP Basic Auth required for all operations (download, list, upload)
- **Credentials**: Auto-generated and stored in AWS Secrets Manager; Terraform state must be treated as sensitive
- **Encryption**: EFS encrypted at rest with AWS-managed KMS key; HTTPS enforced
- **IAM**: Least-privilege IAM roles for ECS tasks and backup operations
- **Access Control**: Use `secret_readers` variable to grant specific IAM roles access to credentials
<!-- BEGIN_TF_DOCS -->

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.11, < 7.0.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.11, < 7.0.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.6 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_pypiserver"></a> [pypiserver](#module\_pypiserver) | registry.infrahouse.com/infrahouse/ecs/aws | 6.1.0 |
| <a name="module_pypiserver_secret"></a> [pypiserver\_secret](#module\_pypiserver\_secret) | registry.infrahouse.com/infrahouse/secret/aws | 1.1.1 |

## Resources

| Name | Type |
|------|------|
| [aws_backup_plan.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_plan) | resource |
| [aws_backup_selection.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_selection) | resource |
| [aws_backup_vault.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_cloudwatch_metric_alarm.efs_burst_credit_balance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.efs_throughput_utilization](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_efs_file_system.packages-enc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.packages-enc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_iam_role.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.backup_restore](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_sns_topic.alarms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.alarm_emails](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_vpc_security_group_ingress_rule.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.efs_icmp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_password.password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_pet.username](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.backup_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_internet_gateway.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/internet_gateway) | data source |
| [aws_kms_key.efs_default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_key) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route53_zone.zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_subnet.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_log_force_destroy"></a> [access\_log\_force\_destroy](#input\_access\_log\_force\_destroy) | Force destroy the S3 bucket containing access logs even if it's not empty.<br/>Should be set to true in test environments to allow clean teardown. | `bool` | `false` | no |
| <a name="input_alarm_emails"></a> [alarm\_emails](#input\_alarm\_emails) | List of email addresses to receive alarm notifications.<br/>AWS will send confirmation emails that must be accepted.<br/>At least one email is required for CloudWatch alarm notifications. | `list(string)` | n/a | yes |
| <a name="input_alarm_topic_arns"></a> [alarm\_topic\_arns](#input\_alarm\_topic\_arns) | List of existing SNS topic ARNs to send alarms to.<br/>Useful for advanced integrations like PagerDuty, Slack, etc.<br/>These are in addition to the email notifications. | `list(string)` | `[]` | no |
| <a name="input_ami_id"></a> [ami\_id](#input\_ami\_id) | AMI ID for EC2 instances in the Auto Scaling Group.<br/>If not specified, the latest Amazon Linux 2023 image will be used. | `string` | `null` | no |
| <a name="input_asg_instance_type"></a> [asg\_instance\_type](#input\_asg\_instance\_type) | EC2 instance type for Auto Scaling Group instances.<br/>Must be a valid AWS instance type. | `string` | `"t3.micro"` | no |
| <a name="input_asg_max_size"></a> [asg\_max\_size](#input\_asg\_max\_size) | Maximum number of instances in Auto Scaling Group.<br/>If null, calculated based on number of tasks and their memory requirements. | `number` | `null` | no |
| <a name="input_asg_min_size"></a> [asg\_min\_size](#input\_asg\_min\_size) | Minimum number of instances in Auto Scaling Group.<br/>If null, defaults to the number of subnets. | `number` | `null` | no |
| <a name="input_asg_subnets"></a> [asg\_subnets](#input\_asg\_subnets) | List of subnet IDs where Auto Scaling Group instances will be launched.<br/>Must contain at least one subnet. | `list(string)` | n/a | yes |
| <a name="input_backup_retention_days"></a> [backup\_retention\_days](#input\_backup\_retention\_days) | Number of days to retain EFS backups.<br/>Only used when enable\_efs\_backup is true. | `number` | `7` | no |
| <a name="input_backup_schedule"></a> [backup\_schedule](#input\_backup\_schedule) | Cron expression for backup schedule.<br/>Default is daily at 2 AM UTC: "cron(0 2 * * ? *)"<br/>Only used when enable\_efs\_backup is true. | `string` | `"cron(0 2 * * ? *)"` | no |
| <a name="input_cloudinit_extra_commands"></a> [cloudinit\_extra\_commands](#input\_cloudinit\_extra\_commands) | Additional cloud-init commands to execute during ASG instance initialization.<br/>Commands are run after the default setup. | `list(string)` | `[]` | no |
| <a name="input_dns_names"></a> [dns\_names](#input\_dns\_names) | List of DNS hostnames to create in the specified Route53 zone.<br/>These will be A records pointing to the load balancer. | `list(string)` | <pre>[<br/>  "pypiserver"<br/>]</pre> | no |
| <a name="input_docker_image_tag"></a> [docker\_image\_tag](#input\_docker\_image\_tag) | Docker image tag for PyPI server.<br/>Defaults to 'latest'. For production, pin to a specific version (e.g., 'v2.3.0').<br/>Available tags: https://hub.docker.com/r/pypiserver/pypiserver/tags | `string` | `"latest"` | no |
| <a name="input_efs_burst_credit_threshold"></a> [efs\_burst\_credit\_threshold](#input\_efs\_burst\_credit\_threshold) | Minimum EFS burst credit balance before triggering an alarm.<br/>EFS burst credits allow temporary higher throughput. Low credits can impact performance.<br/>Default: 1000000000000 (1 trillion bytes, approximately 1TB of burst capacity). | `number` | `1000000000000` | no |
| <a name="input_efs_lifecycle_policy"></a> [efs\_lifecycle\_policy](#input\_efs\_lifecycle\_policy) | Number of days after which files are moved to EFS Infrequent Access storage class.<br/>Valid values: null (disabled), 7, 14, 30, 60, or 90 days.<br/>Moving old package versions to IA storage can reduce costs by up to 92%.<br/>Set to null to disable lifecycle policy. | `number` | `30` | no |
| <a name="input_enable_efs_backup"></a> [enable\_efs\_backup](#input\_enable\_efs\_backup) | Enable AWS Backup for the EFS file system containing PyPI packages.<br/>When enabled, creates a backup vault, plan, and selection.<br/>Set to false in dev/test environments to reduce costs if backups are not needed. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name used for resource tagging and naming.<br/>Examples: development, staging, production. | `string` | `"development"` | no |
| <a name="input_extra_instance_profile_permissions"></a> [extra\_instance\_profile\_permissions](#input\_extra\_instance\_profile\_permissions) | Additional IAM policy document in JSON format to attach to the ASG instance profile.<br/>Useful for granting access to S3, DynamoDB, etc. | `string` | `null` | no |
| <a name="input_load_balancer_subnets"></a> [load\_balancer\_subnets](#input\_load\_balancer\_subnets) | List of subnet IDs where the Application Load Balancer will be placed.<br/>Must be in different Availability Zones for high availability. | `list(string)` | n/a | yes |
| <a name="input_secret_readers"></a> [secret\_readers](#input\_secret\_readers) | List of IAM role ARNs that will have read permissions for the PyPI authentication secret.<br/>The secret is stored in AWS Secrets Manager. | `list(string)` | `null` | no |
| <a name="input_service_name"></a> [service\_name](#input\_service\_name) | Name of the PyPI service.<br/>Used for resource naming and tagging throughout the module. | `string` | `"pypiserver"` | no |
| <a name="input_task_max_count"></a> [task\_max\_count](#input\_task\_max\_count) | Maximum number of ECS tasks to run.<br/>Used for auto-scaling the PyPI service. | `number` | `10` | no |
| <a name="input_task_min_count"></a> [task\_min\_count](#input\_task\_min\_count) | Minimum number of ECS tasks to run.<br/>Used for auto-scaling the PyPI service. | `number` | `2` | no |
| <a name="input_users"></a> [users](#input\_users) | A list of maps with user definitions according to the cloud-init format.<br/>See https://cloudinit.readthedocs.io/en/latest/reference/examples.html#including-users-and-groups<br/>for field descriptions and examples. | <pre>list(<br/>    object(<br/>      {<br/>        name                = string<br/>        expiredate          = optional(string)<br/>        gecos               = optional(string)<br/>        homedir             = optional(string)<br/>        primary_group       = optional(string)<br/>        groups              = optional(string) # Comma separated list of strings e.g. "users,admin"<br/>        selinux_user        = optional(string)<br/>        lock_passwd         = optional(bool)<br/>        inactive            = optional(number)<br/>        passwd              = optional(string)<br/>        no_create_home      = optional(bool)<br/>        no_user_group       = optional(bool)<br/>        no_log_init         = optional(bool)<br/>        ssh_import_id       = optional(list(string))<br/>        ssh_authorized_keys = optional(list(string))<br/>        sudo                = optional(any) # Can be false or a list of strings e.g. ["ALL=(ALL) NOPASSWD:ALL"]<br/>        system              = optional(bool)<br/>        snapuser            = optional(string)<br/>      }<br/>    )<br/>  )</pre> | `[]` | no |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route53 hosted zone ID where DNS records will be created.<br/>Used for the service endpoint and certificate validation. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_asg_name"></a> [asg\_name](#output\_asg\_name) | Name of the Auto Scaling Group for ECS container instances. |
| <a name="output_cloudwatch_alarm_arns"></a> [cloudwatch\_alarm\_arns](#output\_cloudwatch\_alarm\_arns) | ARNs of CloudWatch alarms created for EFS monitoring. |
| <a name="output_cloudwatch_alarm_sns_topic_arn"></a> [cloudwatch\_alarm\_sns\_topic\_arn](#output\_cloudwatch\_alarm\_sns\_topic\_arn) | ARN of the SNS topic used for CloudWatch alarm notifications. |
| <a name="output_ecs_service_arn"></a> [ecs\_service\_arn](#output\_ecs\_service\_arn) | ARN of the ECS service running the PyPI server. |
| <a name="output_pypi_load_balancer_arn"></a> [pypi\_load\_balancer\_arn](#output\_pypi\_load\_balancer\_arn) | ARN of the PyPI server load balancer. |
| <a name="output_pypi_password"></a> [pypi\_password](#output\_pypi\_password) | Password to access PyPI server. |
| <a name="output_pypi_server_urls"></a> [pypi\_server\_urls](#output\_pypi\_server\_urls) | List of PyPI server URLs. |
| <a name="output_pypi_user_secret"></a> [pypi\_user\_secret](#output\_pypi\_user\_secret) | AWS secret that stores PyPI username/password |
| <a name="output_pypi_user_secret_arn"></a> [pypi\_user\_secret\_arn](#output\_pypi\_user\_secret\_arn) | AWS secret ARN that stores PyPI username/password |
| <a name="output_pypi_username"></a> [pypi\_username](#output\_pypi\_username) | Username to access PyPI server. |
<!-- END_TF_DOCS -->
