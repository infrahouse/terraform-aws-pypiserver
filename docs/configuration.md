# Configuration

All variables are documented below, grouped by function. For the full reference
table see the [README](https://github.com/infrahouse/terraform-aws-pypiserver#inputs).

## Required Variables

These must be provided -- no defaults.

### `asg_subnets`

Subnet IDs for ECS container instances. At least one private subnet is required.

```hcl
asg_subnets = data.aws_subnets.private.ids
```

### `load_balancer_subnets`

Subnet IDs for the ALB. At least two subnets in different AZs.

```hcl
load_balancer_subnets = data.aws_subnets.public.ids
```

### `zone_id`

Route53 hosted zone ID for DNS records and ACM certificate validation.

```hcl
zone_id = data.aws_route53_zone.main.zone_id
```

### `alarm_emails`

Email addresses for CloudWatch alarm notifications. AWS sends confirmation
emails that must be accepted.

```hcl
alarm_emails = ["ops@example.com", "oncall@example.com"]
```

## Naming and DNS

### `service_name`

Name used for resource naming and tagging. Default: `"pypiserver"`.

```hcl
service_name = "pypi"
```

### `dns_names`

DNS hostnames to create in the Route53 zone. Default: `["pypiserver"]`.

```hcl
# Creates pypi.example.com and packages.example.com
dns_names = ["pypi", "packages"]
```

### `environment`

Environment tag for resources. Default: `"development"`.

```hcl
environment = "production"
```

## Scaling and Sizing

The module auto-calculates task counts from instance type. Override only when needed.

### `asg_instance_type`

EC2 instance type. Must have enough RAM for containers + page cache + system
overhead. Default: `"t3.small"`.

```hcl
# Heavy workload
asg_instance_type = "c6a.xlarge"
```

### `asg_min_size` / `asg_max_size`

ASG bounds. Default: `null` (auto-calculated from subnets and task requirements).

```hcl
asg_min_size = 2
asg_max_size = 4
```

### `task_min_count` / `task_max_count`

ECS task bounds. Default: `null` (auto-calculated from instance capacity).

```hcl
task_min_count = 6
task_max_count = 12
```

See [Sizing](SIZING.md) for detailed capacity planning.

## Container Resources

### `container_memory`

Hard memory limit in MB. Container is killed if exceeded. Default: `512`.

```hcl
container_memory = 1024  # Heavy workload
```

### `container_memory_reservation`

Soft memory limit in MB. Default: `null` (75% of `container_memory`).

```hcl
container_memory_reservation = 384
```

### `container_cpu`

CPU units (1024 = 1 vCPU). Default: `null` (auto-calculated from workers).

```hcl
container_cpu = 512
```

### `gunicorn_workers`

Workers per container. Default: `null` (auto-calculated from memory).

```hcl
gunicorn_workers = 4
```

### `docker_image_tag`

Pypiserver Docker image tag. Default: `"latest"`. Pin for production.

```hcl
docker_image_tag = "v2.3.0"
```

## EFS Storage

### `efs_throughput_mode`

EFS throughput mode. Default: `"elastic"` (recommended).

```hcl
# Options: "elastic", "bursting", "provisioned"
efs_throughput_mode = "elastic"
```

- **elastic**: Pay-per-use, no burst credits to manage
- **bursting**: Free with storage, but credits deplete on small filesystems
- **provisioned**: Fixed throughput (set `efs_provisioned_throughput_in_mibps`)

### `efs_provisioned_throughput_in_mibps`

Only used with `efs_throughput_mode = "provisioned"`. Range: 1-3414 MiB/s.

```hcl
efs_throughput_mode                 = "provisioned"
efs_provisioned_throughput_in_mibps = 10
```

### `efs_lifecycle_policy`

Days before files move to Infrequent Access storage. Default: `30`.
Set to `null` to disable.

```hcl
efs_lifecycle_policy = 60  # Move after 60 days
```

## Backups

### `enable_efs_backup`

Enable AWS Backup for EFS. Default: `true`.

```hcl
enable_efs_backup = false  # Dev environment
```

### `backup_retention_days`

Days to retain backups. Default: `7`.

```hcl
backup_retention_days = 30
```

### `backup_schedule`

Cron expression for backup schedule. Default: `"cron(0 2 * * ? *)"` (daily 2 AM UTC).

```hcl
backup_schedule = "cron(0 3 * * ? *)"  # 3 AM UTC
```

## Monitoring

### `enable_cloudwatch_dashboard`

Create a CloudWatch dashboard. Default: `true`.

### `alarm_topic_arns`

Additional SNS topic ARNs for alarm delivery (e.g. PagerDuty, Slack). Default: `[]`.

```hcl
alarm_topic_arns = [aws_sns_topic.pagerduty.arn]
```

### `efs_burst_credit_threshold`

Burst credit alarm threshold. Only relevant with `efs_throughput_mode = "bursting"`.
Default: `1000000000000` (1 TB).

## Security and Access

### `secret_readers`

IAM role ARNs granted read access to the credentials secret.

```hcl
secret_readers = [
  "arn:aws:iam::123456789012:role/ci-runner"
]
```

### `users`

SSH users for debugging EC2 instances (optional).

```hcl
users = [
  {
    name                = "admin"
    groups              = "wheel"
    sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys = ["ssh-rsa AAAA..."]
  }
]
```

## Advanced

### `ami_id`

Override the AMI for EC2 instances. Default: `null` (latest Amazon Linux 2023).

### `extra_instance_profile_permissions`

Additional IAM policy JSON for instance profile.

### `cloudinit_extra_commands`

Additional cloud-init commands for instance initialization.

### `extra_files`

Additional files to deploy to instances.

### `access_log_force_destroy` / `backups_force_destroy`

Force-destroy S3 bucket and backup vault during teardown.
Set to `true` in test environments.
