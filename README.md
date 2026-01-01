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

## Performance & Production Guidelines

### Tested Baseline Configuration

The module has been stress-tested with the following configuration:
- **Instance Type**: 2 × `c6a.xlarge` (4 vCPU, 8 GB RAM each, compute-optimized)
- **ALB Algorithm**: `round_robin` (default)
- **Total Capacity**: 12 ECS tasks × 4 gunicorn workers = 48 concurrent workers
- **Cost**: ~$220/month

### Performance Characteristics

Under production incident simulation (510 simultaneous download requests):
- **Error Rate**: 0.05% (3 failures / 6,273 requests)
- **P95 Latency**: 14 seconds
- **P99 Latency**: 20 seconds
- **Throughput**: 20 requests/second
- **5xx Errors**: < 10 per test run

### Known Limitations

1. **HTTP Keep-Alive Connection Stickiness**
   - ALB round-robin distributes connections at establishment only
   - Burst traffic (500+ simultaneous requests) often concentrates on one instance
   - Load cannot be rebalanced for existing connections
   - High latency during bursts is expected behavior

2. **Python + EFS Without Caching**
   - Uses `--backend simple-dir` (no caching) to prevent cache sync issues
   - Every request scans EFS directory structure
   - Inherently slower than cached backends
   - Trade-off: Consistency vs Performance

3. **Burst Traffic Patterns**
   - System is optimized for sustained load, not instantaneous spikes
   - 510 simultaneous requests from cold start will see elevated latency
   - Normal pip install patterns (gradual requests) perform much better

### Scaling Recommendations

**"Fewer, Beefier Instances" Strategy:**
- ✅ Use compute-optimized instances (c6a, c7a family)
- ✅ Minimize number of instances to reduce ALB target variance
- ✅ Provide CPU headroom to absorb burst traffic concentration
- ❌ Avoid many small instances (increases load distribution variance)

**Example Configurations:**

| Workload | Instances | Type | vCPUs | Cost/mo | Notes |
|----------|-----------|------|-------|---------|-------|
| Light (<50 packages) | 2 | t3.small | 4 total | ~$60 | Default, good for dev/test |
| Medium (50-200 packages) | 2 | c6a.large | 4 total | ~$110 | Better burst handling |
| **Heavy (200+ packages, production)** | **2** | **c6a.xlarge** | **8 total** | **~$220** | **Tested baseline, recommended** |
| Very Heavy | 2 | c6a.2xlarge | 16 total | ~$440 | Maximum capacity |

### Future Optimization Opportunities

If sub-second latency is required, consider:
1. **Caching Backend**: Switch from `simple-dir` to cached backend (requires cache invalidation strategy)
2. **CloudFront CDN**: Add CloudFront in front of ALB for static package file caching
3. **Connection Limits**: Configure ALB connection limits per target to force better distribution
4. **Least Outstanding Requests**: Try `least_outstanding_requests` ALB algorithm (may help with sustained load)

### Production Recommendations

For production deployments:
1. Use `c6a.xlarge` or larger (tested and validated)
2. Set `asg_min_size = 2` for high availability
3. Monitor CloudWatch alarms for EFS burst credits
4. Keep `enable_efs_backup = true` for disaster recovery
5. Expect 10-20 second P95 latency for burst traffic patterns
6. Plan for ~0.05% error rate under extreme load (acceptable for internal PyPI)

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
  version = "2.1.0"

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

## Performance Tuning

This module uses `--backend simple-dir` to ensure consistency across distributed containers, which disables
pypiserver's in-memory cache. Performance depends primarily on:

1. **Instance Memory**: More RAM = better page cache for EFS metadata operations
2. **Container Memory**: Controls container memory limits and reservations
3. **EFS Burst Credits**: Monitor via CloudWatch alarms

### Container Resource Configuration

Use the following variables to tune container resources for your workload:

```hcl
module "pypiserver" {
  source = "infrahouse/pypiserver/aws"

  # Container resource limits
  container_memory             = 512   # Hard limit (MB) - container killed if exceeded
  container_memory_reservation = 384   # Soft limit (MB) - defaults to 75% of container_memory if null
  container_cpu                = 256   # CPU units (1024 = 1 vCPU)

  # Instance type should have enough memory for containers + page cache + system overhead
  asg_instance_type = "t3.small"  # 2 GB RAM
}
```

### Sizing Recommendations

> **Default Configuration**: The module defaults (`asg_instance_type = "t3.small"`, `container_memory = 512 MB`) are optimized for medium workloads. You can adjust these for lighter or heavier loads.

**Light Workload** (< 50 packages, < 5 concurrent users):
```hcl
# For minimal cost, reduce container memory:
asg_instance_type = "t3.small"  # 2 GB RAM (default)
container_memory  = 256         # Reduced from default
container_cpu     = 256         # Default
```

**Medium Workload** (50-200 packages, 5-20 concurrent users) - **Default Configuration**:
```hcl
# Use defaults - no configuration needed:
asg_instance_type = "t3.small"  # 2 GB RAM (default)
container_memory  = 512         # Default
container_cpu     = 256         # Default
```

**Heavy Workload** (200+ packages, 20+ concurrent users):
```hcl
# Increase instance size and container memory:
asg_instance_type = "t3.medium"  # 4 GB RAM
container_memory  = 1024
container_cpu     = 512
```

### Memory Requirements

The module requires sufficient instance memory for:
- **Container allocation**: `container_memory` × number of tasks per instance
- **Page cache**: ~512 MB minimum for EFS metadata caching
- **System overhead**: ~300 MB for ECS agent, CloudWatch, and OS

**Example calculation**:
```
Instance RAM = (container_memory × tasks_per_instance) + page_cache + system
             = (512 MB × 2) + 512 MB + 300 MB
             = 1836 MB ≈ 2 GB (t3.small)
```

### When to Increase Resources

- **Memory**: If you see swap activity, high iowait%, or OOM kills
- **CPU**: If CPU utilization consistently > 70%
- **Instance Type**: If available memory < 500 MB or container_memory × tasks doesn't fit

See [docs/SIZING.md](docs/SIZING.md) for comprehensive sizing guidance and capacity planning.

## Monitoring

### Key Metrics to Watch

The module creates CloudWatch alarms for critical metrics. Monitor these to ensure healthy operation:

1. **EFS Burst Credits** (`BurstCreditBalance`):
   - **What it means**: Available performance credits for burst throughput
   - **Alarm triggers**: When < 1 TB (1,000,000,000,000 bytes)
   - **Impact if low**: Degraded EFS performance, slower package downloads
   - **Solution**: Enable provisioned throughput or optimize file operations

2. **EFS Throughput Utilization** (`PercentIOLimit`):
   - **What it means**: Percentage of maximum I/O throughput being used
   - **Alarm triggers**: When > 80% sustained
   - **Impact if high**: Requests may be throttled
   - **Solution**: Enable provisioned throughput mode

3. **Container Memory** (ECS metrics):
   - **What it means**: RAM usage per container
   - **Where to check**: ECS Console → Service → Metrics, or CloudWatch Container Insights
   - **Impact if high**: Containers near limit may be OOM killed
   - **Solution**: Increase `container_memory` variable

4. **Host Swap Usage**:
   - **What it means**: Instance is using swap space (disk as RAM)
   - **Where to check**: Systems Manager → Fleet Manager, or SSH to instance
   - **Impact if present**: Any swap usage indicates memory pressure and degrades performance
   - **Solution**: Increase instance type (more RAM)

5. **Request Latency** (ALB metrics):
   - **What it means**: Time for backend to respond to requests
   - **Metric name**: `TargetResponseTime` (P95, P99)
   - **Target**: P95 < 2 seconds for normal load, < 15 seconds for extreme bursts
   - **Impact if high**: Slow pip/poetry installs for users
   - **Solution**: Scale tasks or increase instance size

### Accessing Metrics

**AWS Console**:
- EFS metrics: AWS Console → EFS → File Systems → [your-fs] → Monitoring
- ECS metrics: AWS Console → ECS → Clusters → [cluster] → Services → [service] → Metrics
- ALB metrics: AWS Console → EC2 → Load Balancers → [lb] → Monitoring

**CloudWatch CLI**:
```bash
# Check EFS burst credits
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name BurstCreditBalance \
  --dimensions Name=FileSystemId,Value=fs-xxxxx \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average

# Check container memory usage
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ServiceName,Value=pypiserver \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average,Maximum
```

### Alarm Notifications

The module creates SNS topics for alarm notifications. Check your email for:
- **Alarm name**: `{service_name}-efs-burst-credits` or `{service_name}-efs-throughput`
- **Action required**: Follow the solution steps in the alarm description
- **Severity**: All EFS alarms are critical and should be addressed promptly

## Troubleshooting

### Slow Package Listing

**Symptoms**: `pip install` or `poetry install` takes > 5 seconds to resolve package index

**Possible Causes**:
1. EFS burst credits depleted
2. Instance swapping due to low memory
3. Too many packages (> 1000) causing metadata bottleneck

**Diagnosis**:
```bash
# 1. Check EFS burst credits (via AWS CLI or Console)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name BurstCreditBalance \
  --dimensions Name=FileSystemId,Value=$(terraform output -raw efs_file_system_id) \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Minimum

# 2. SSH to instance and check swap activity
aws ssm start-session --target <instance-id>
vmstat 1 5  # Watch si/so columns - should be 0
free -m     # Check available memory

# 3. Check package count
ls /mnt/packages | wc -l
```

**Solutions**:
1. If credits < 1 TB: Enable EFS provisioned throughput
2. If swap columns (si/so) are non-zero: Increase `asg_instance_type`
3. If available memory < 500 MB: Increase `container_memory` or instance size
4. For 1000+ packages: Consider CloudFront caching layer (external to module)

---

### Container OOM Kills

**Symptoms**: Tasks restarting frequently; ECS events show "OutOfMemory" or "Essential container in task exited"

**Cause**: Container memory limit (`container_memory`) is too low for workload

**Diagnosis**:
```bash
# Check ECS service events
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  | jq '.services[0].events[] | select(.message | contains("OutOfMemory"))'

# Check container memory metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ServiceName,Value=pypiserver \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Maximum
```

**Solutions**:
1. Increase `container_memory` to 512 MB or 1024 MB
2. Reduce `task_min_count` to allocate more memory per task
3. Increase instance type if tasks won't fit

---

### High iowait on Hosts

**Symptoms**: Slow responses; CloudWatch shows high CPU wait time

**Causes**:
1. Insufficient page cache (instance memory too small)
2. EFS throttling
3. Swap activity

**Diagnosis**:
```bash
# SSH to instance and check iowait
aws ssm start-session --target <instance-id>

# Check iowait % (wa column should be < 10%)
vmstat 1 5

# Check if swapping is occurring
cat /proc/meminfo | grep -E 'MemAvailable|SwapTotal|SwapFree'

# Check EFS mount stats
cat /proc/self/mountstats | grep -A20 "mounted on /data/packages"
```

**Solutions**:
1. If `SwapFree` < `SwapTotal`: Swapping is active → increase instance size immediately
2. If `MemAvailable` < 500 MB: Increase instance size or reduce container memory
3. Check CloudWatch for EFS throttling metrics (`PercentIOLimit`)

---

### Authentication Failures

**Symptoms**: `pip install` or `twine upload` returns 401 Unauthorized

**Causes**:
1. Incorrect credentials
2. Special characters in password not URL-encoded
3. Credentials not yet propagated from Secrets Manager

**Diagnosis**:
```bash
# Retrieve current credentials
terraform output -raw pypi_username
terraform output -raw pypi_password

# Test authentication with curl
curl -u "$(terraform output -raw pypi_username):$(terraform output -raw pypi_password)" \
  https://$(terraform output -raw pypi_server_urls | jq -r '.[0]')/simple/
```

**Solutions**:
1. Verify credentials match Terraform outputs
2. URL-encode password if it contains special characters:
   ```bash
   python3 -c "import urllib.parse; print(urllib.parse.quote(input('Password: ')))"
   ```
3. Configure pip/poetry with credentials:
   ```bash
   # ~/.pip/pip.conf
   [global]
   index-url = https://username:password@pypi.example.com/simple/
   extra-index-url = https://pypi.org/simple

   # OR use environment variable
   export PIP_INDEX_URL=https://username:password@pypi.example.com/simple/
   ```

---

### Package Upload Fails

**Symptoms**: `twine upload` returns 5xx error or times out

**Possible Causes**:
1. EFS storage full (rare, EFS auto-expands)
2. Container out of memory during upload
3. Package too large (> 100 MB)
4. Network timeout

**Diagnosis**:
```bash
# Check EFS usage
aws efs describe-file-systems \
  --file-system-id $(terraform output -raw efs_file_system_id) \
  | jq '.FileSystems[0].SizeInBytes'

# Check recent container events
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  | jq '.services[0].events[0:5]'

# Try uploading with verbose output
twine upload --verbose --repository-url https://pypi.example.com dist/*.whl
```

**Solutions**:
1. If EFS near quota (rare): Contact AWS support to increase limit
2. If container OOMkilled during upload: Increase `container_memory`
3. For packages > 100 MB: Split into smaller packages or use S3-backed PyPI alternative
4. Increase twine timeout: `twine upload --timeout 300`

---

### High Error Rate During Bursts

**Symptoms**: Many 502 Bad Gateway or connection timeout errors when many CI jobs run simultaneously

**Expected Behavior**:
- < 1% error rate is normal for extreme bursts (500+ simultaneous requests)
- 10-20 second P95 latency during bursts is expected with current architecture

**Diagnosis**:
```bash
# Check ALB target health
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  | jq '.TargetHealthDescriptions[] | {Target: .Target.Id, State: .TargetHealth.State}'

# Check ECS task count
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  | jq '.services[0] | {desired: .desiredCount, running: .runningCount, pending: .pendingCount}'
```

**Solutions (if error rate > 1%)**:
1. Increase instance type: `c6a.xlarge` or `c6a.2xlarge`
2. Ensure using "fewer, beefier instances" strategy (not many small instances)
3. Check [docs/SIZING.md](docs/SIZING.md) for capacity planning
4. Consider application-level solutions: Stagger CI job starts with random jitter (0-60s)

**Note**: Due to HTTP keep-alive connection stickiness, burst traffic often concentrates on one instance. This is fundamental ALB behavior and expected. The solution is provisioning enough CPU per instance to handle it.

---

For more detailed troubleshooting and performance tuning, see [docs/SIZING.md](docs/SIZING.md).

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
| <a name="module_pypiserver"></a> [pypiserver](#module\_pypiserver) | registry.infrahouse.com/infrahouse/ecs/aws | 7.1.0 |
| <a name="module_pypiserver_secret"></a> [pypiserver\_secret](#module\_pypiserver\_secret) | registry.infrahouse.com/infrahouse/secret/aws | 1.1.1 |

## Resources

| Name | Type |
|------|------|
| [aws_backup_plan.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_plan) | resource |
| [aws_backup_selection.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_selection) | resource |
| [aws_backup_vault.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_cloudwatch_dashboard.pypiserver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
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
| [aws_ec2_instance_type.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ec2_instance_type) | data source |
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
| <a name="input_asg_instance_type"></a> [asg\_instance\_type](#input\_asg\_instance\_type) | EC2 instance type for Auto Scaling Group instances.<br/><br/>The instance must have sufficient memory for:<br/>- Container allocation: container\_memory × tasks\_per\_instance<br/>- Page cache: ~512 MB minimum (critical for EFS metadata caching with --backend simple-dir)<br/>- System overhead: ~300 MB (ECS agent, CloudWatch, OS)<br/><br/>Minimum memory calculation:<br/>  Required RAM = (container\_memory × tasks\_per\_instance) + 512 MB + 300 MB<br/><br/>Recommended instance types:<br/>- Light workload (< 50 packages): t3.micro (1 GB) with container\_memory=256<br/>- Medium workload (50-200 packages): t3.small (2 GB) with container\_memory=512 (default)<br/>- Heavy workload (200+ packages): t3.medium (4 GB) with container\_memory=1024<br/><br/>Using an instance that's too small will cause swap activity, leading to high iowait<br/>and degraded performance under load. | `string` | `"t3.small"` | no |
| <a name="input_asg_max_size"></a> [asg\_max\_size](#input\_asg\_max\_size) | Maximum number of instances in Auto Scaling Group.<br/>If null, calculated based on number of tasks and their memory requirements. | `number` | `null` | no |
| <a name="input_asg_min_size"></a> [asg\_min\_size](#input\_asg\_min\_size) | Minimum number of instances in Auto Scaling Group.<br/>If null, defaults to the number of subnets. | `number` | `null` | no |
| <a name="input_asg_subnets"></a> [asg\_subnets](#input\_asg\_subnets) | List of subnet IDs where Auto Scaling Group instances will be launched.<br/>Must contain at least one subnet. | `list(string)` | n/a | yes |
| <a name="input_backup_retention_days"></a> [backup\_retention\_days](#input\_backup\_retention\_days) | Number of days to retain EFS backups.<br/>Only used when enable\_efs\_backup is true. | `number` | `7` | no |
| <a name="input_backup_schedule"></a> [backup\_schedule](#input\_backup\_schedule) | Cron expression for backup schedule.<br/>Default is daily at 2 AM UTC: "cron(0 2 * * ? *)"<br/>Only used when enable\_efs\_backup is true. | `string` | `"cron(0 2 * * ? *)"` | no |
| <a name="input_backups_force_destroy"></a> [backups\_force\_destroy](#input\_backups\_force\_destroy) | Force destroy the backup vault even if it contains recovery points.<br/>Should be set to true in test environments to allow clean teardown.<br/>WARNING: Setting this to true will delete all backups when destroying the vault. | `bool` | `false` | no |
| <a name="input_cloudinit_extra_commands"></a> [cloudinit\_extra\_commands](#input\_cloudinit\_extra\_commands) | Additional cloud-init commands to execute during ASG instance initialization.<br/>Commands are run after the default setup. | `list(string)` | `[]` | no |
| <a name="input_container_cpu"></a> [container\_cpu](#input\_container\_cpu) | CPU units to allocate to the PyPI container.<br/>1024 CPU units = 1 vCPU.<br/><br/>If null (default), automatically calculated based on gunicorn workers:<br/>  formula: (gunicorn\_workers × 150) + 40<br/><br/>This formula accounts for ~128 CPU units of system overhead (ECS agent, CloudWatch)<br/>and is calibrated to allow 3 pypiserver tasks per t3.small instance (2 vCPU),<br/>matching the memory-based limit.<br/><br/>Examples with auto-calculation (on t3.small with 2048 CPU - 128 overhead = 1920 available):<br/>  2 workers → 340 CPU units (~0.33 vCPU) → allows 5 tasks on t3.small<br/>  4 workers → 640 CPU units (~0.62 vCPU) → allows 3 tasks on t3.small<br/>  6 workers → 940 CPU units (~0.92 vCPU) → allows 2 tasks on t3.small<br/><br/>Override this value to manually control CPU reservation for specific needs. | `number` | `null` | no |
| <a name="input_container_memory"></a> [container\_memory](#input\_container\_memory) | Memory limit for the PyPI container in MB.<br/>This is the hard memory limit - the container will be killed if it exceeds this value.<br/><br/>With --backend simple-dir, pypiserver scans directories on every request.<br/>More memory allows better page cache performance for EFS metadata.<br/><br/>Recommended values:<br/>- Light workload (< 50 packages, < 5 users): 256 MB<br/>- Medium workload (50-200 packages, 5-20 users): 512 MB (default)<br/>- Heavy workload (200+ packages, 20+ users): 1024 MB<br/><br/>Default: 512 MB (optimized for medium workloads)<br/>Minimum: 128 MB (only suitable for very light workloads) | `number` | `512` | no |
| <a name="input_container_memory_reservation"></a> [container\_memory\_reservation](#input\_container\_memory\_reservation) | Soft memory limit for the PyPI container in MB.<br/>This is the amount of memory reserved for the container on the host instance.<br/>The container can use more memory up to the container\_memory limit.<br/><br/>If null, defaults to 75% of container\_memory to allow some burst capacity<br/>while preventing overcommitment of host resources.<br/><br/>Set to a specific value if you want precise control over memory reservation.<br/>Set to 0 to disable soft limit (not recommended). | `number` | `null` | no |
| <a name="input_dns_names"></a> [dns\_names](#input\_dns\_names) | List of DNS hostnames to create in the specified Route53 zone.<br/>These will be A records pointing to the load balancer. | `list(string)` | <pre>[<br/>  "pypiserver"<br/>]</pre> | no |
| <a name="input_docker_image_tag"></a> [docker\_image\_tag](#input\_docker\_image\_tag) | Docker image tag for PyPI server.<br/>Defaults to 'latest'. For production, pin to a specific version (e.g., 'v2.3.0').<br/>Available tags: https://hub.docker.com/r/pypiserver/pypiserver/tags | `string` | `"latest"` | no |
| <a name="input_efs_burst_credit_threshold"></a> [efs\_burst\_credit\_threshold](#input\_efs\_burst\_credit\_threshold) | Minimum EFS burst credit balance before triggering an alarm.<br/>EFS burst credits allow temporary higher throughput. Low credits can impact performance.<br/>Default: 1000000000000 (1 trillion bytes, approximately 1TB of burst capacity). | `number` | `1000000000000` | no |
| <a name="input_efs_lifecycle_policy"></a> [efs\_lifecycle\_policy](#input\_efs\_lifecycle\_policy) | Number of days after which files are moved to EFS Infrequent Access storage class.<br/>Valid values: null (disabled), 7, 14, 30, 60, or 90 days.<br/>Moving old package versions to IA storage can reduce costs by up to 92%.<br/>Set to null to disable lifecycle policy. | `number` | `30` | no |
| <a name="input_enable_cloudwatch_dashboard"></a> [enable\_cloudwatch\_dashboard](#input\_enable\_cloudwatch\_dashboard) | Create a CloudWatch dashboard for monitoring PyPI server metrics.<br/><br/>The dashboard includes:<br/>- ECS service metrics (CPU, memory, task count)<br/>- ALB metrics (response time, request count, HTTP status codes, target health)<br/>- EFS metrics (burst credits, throughput utilization, I/O operations)<br/>- Container Insights metrics (CPU and memory per container)<br/><br/>The dashboard provides a centralized view of all critical metrics for<br/>monitoring performance, troubleshooting issues, and capacity planning.<br/><br/>Set to false to disable dashboard creation (not recommended for production). | `bool` | `true` | no |
| <a name="input_enable_efs_backup"></a> [enable\_efs\_backup](#input\_enable\_efs\_backup) | Enable AWS Backup for the EFS file system containing PyPI packages.<br/>When enabled, creates a backup vault, plan, and selection.<br/>Set to false in dev/test environments to reduce costs if backups are not needed. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name used for resource tagging and naming.<br/>Examples: development, staging, production. | `string` | `"development"` | no |
| <a name="input_extra_files"></a> [extra\_files](#input\_extra\_files) | Additional files to deploy to EC2 instances during initialization.<br/>Each file should have: content, path, and permissions.<br/>Example usage in calling module:<br/>  extra\_files = [<br/>    {<br/>      content     = file("${path.module}/files/script.sh")<br/>      path        = "/opt/scripts/script.sh"<br/>      permissions = "755"<br/>    }<br/>  ] | <pre>list(<br/>    object({<br/>      content     = string<br/>      path        = string<br/>      permissions = string<br/>    })<br/>  )</pre> | `[]` | no |
| <a name="input_extra_instance_profile_permissions"></a> [extra\_instance\_profile\_permissions](#input\_extra\_instance\_profile\_permissions) | Additional IAM policy document in JSON format to attach to the ASG instance profile.<br/>Useful for granting access to S3, DynamoDB, etc. | `string` | `null` | no |
| <a name="input_gunicorn_workers"></a> [gunicorn\_workers](#input\_gunicorn\_workers) | Number of gunicorn workers per container.<br/><br/>If null (default), automatically calculated based on container memory:<br/>  formula: max(2, min(8, floor(container\_memory / 128)))<br/><br/>Examples with auto-calculation:<br/>  256 MB  → 2 workers<br/>  512 MB  → 4 workers<br/>  768 MB  → 6 workers<br/>  1024 MB → 8 workers<br/><br/>Override this value to tune for specific workload patterns:<br/>- More workers = higher request capacity but more EFS directory scan contention<br/>- Fewer workers = lower capacity but less EFS contention<br/><br/>With --backend simple-dir, each request scans the packages directory on EFS.<br/>If experiencing high latency during bursts, consider reducing worker count<br/>or switching to a caching backend.<br/><br/>Minimum: 1 worker (not recommended for production)<br/>Maximum: 16 workers (gevent can handle many concurrent connections per worker)<br/><br/>Default: null (auto-calculated from container\_memory) | `number` | `null` | no |
| <a name="input_load_balancer_subnets"></a> [load\_balancer\_subnets](#input\_load\_balancer\_subnets) | List of subnet IDs where the Application Load Balancer will be placed.<br/>Must be in different Availability Zones for high availability. | `list(string)` | n/a | yes |
| <a name="input_secret_readers"></a> [secret\_readers](#input\_secret\_readers) | List of IAM role ARNs that will have read permissions for the PyPI authentication secret.<br/>The secret is stored in AWS Secrets Manager. | `list(string)` | `null` | no |
| <a name="input_service_name"></a> [service\_name](#input\_service\_name) | Name of the PyPI service.<br/>Used for resource naming and tagging throughout the module. | `string` | `"pypiserver"` | no |
| <a name="input_task_max_count"></a> [task\_max\_count](#input\_task\_max\_count) | Maximum number of ECS tasks to run.<br/>Used for auto-scaling the PyPI service.<br/><br/>If null (default), automatically calculated as 2 × task\_min\_count to allow<br/>doubling capacity during traffic spikes or scaling events.<br/><br/>Set explicitly to override auto-calculation for specific requirements. | `number` | `null` | no |
| <a name="input_task_min_count"></a> [task\_min\_count](#input\_task\_min\_count) | Minimum number of ECS tasks to run across the entire cluster.<br/><br/>If null (default), automatically calculated to maximize cluster utilization<br/>based on BOTH CPU and RAM constraints (whichever is more restrictive):<br/><br/>  tasks\_per\_instance\_ram = floor(available\_ram / container\_memory\_reservation)<br/>  tasks\_per\_instance\_cpu = floor(available\_cpu / container\_cpu)<br/>  tasks\_per\_instance = min(tasks\_per\_instance\_ram, tasks\_per\_instance\_cpu)<br/>  task\_min\_count = tasks\_per\_instance × number\_of\_instances<br/><br/>Number of instances is determined by asg\_min\_size (or number of subnets if not specified).<br/><br/>Example auto-calculations (with 2 instances, 512 MB containers, 640 CPU units):<br/>  t3.small (2 vCPU, 2 GB):<br/>    - RAM: floor(1248 MB / 384 MB) = 3 tasks<br/>    - CPU: floor(1920 units / 640 units) = 3 tasks<br/>    - Result: min(3, 3) × 2 = 6 tasks total (RAM and CPU balanced)<br/><br/>  c6a.xlarge (4 vCPU, 8 GB):<br/>    - RAM: floor(7392 MB / 384 MB) = 19 tasks<br/>    - CPU: floor(3968 units / 640 units) = 6 tasks<br/>    - Result: min(19, 6) × 2 = 12 tasks total (CPU constrained)<br/><br/>This ensures all instances in the ASG are fully utilized without exceeding resource limits.<br/><br/>Set explicitly to override auto-calculation for specific requirements. | `number` | `null` | no |
| <a name="input_users"></a> [users](#input\_users) | A list of maps with user definitions according to the cloud-init format.<br/>See https://cloudinit.readthedocs.io/en/latest/reference/examples.html#including-users-and-groups<br/>for field descriptions and examples. | <pre>list(<br/>    object(<br/>      {<br/>        name                = string<br/>        expiredate          = optional(string)<br/>        gecos               = optional(string)<br/>        homedir             = optional(string)<br/>        primary_group       = optional(string)<br/>        groups              = optional(string) # Comma separated list of strings e.g. "users,admin"<br/>        selinux_user        = optional(string)<br/>        lock_passwd         = optional(bool)<br/>        inactive            = optional(number)<br/>        passwd              = optional(string)<br/>        no_create_home      = optional(bool)<br/>        no_user_group       = optional(bool)<br/>        no_log_init         = optional(bool)<br/>        ssh_import_id       = optional(list(string))<br/>        ssh_authorized_keys = optional(list(string))<br/>        sudo                = optional(any) # Can be false or a list of strings e.g. ["ALL=(ALL) NOPASSWD:ALL"]<br/>        system              = optional(bool)<br/>        snapuser            = optional(string)<br/>      }<br/>    )<br/>  )</pre> | `[]` | no |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route53 hosted zone ID where DNS records will be created.<br/>Used for the service endpoint and certificate validation. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_asg_name"></a> [asg\_name](#output\_asg\_name) | Name of the Auto Scaling Group for ECS container instances. |
| <a name="output_capacity_info"></a> [capacity\_info](#output\_capacity\_info) | Information about instance capacity and task packing. |
| <a name="output_cloudwatch_alarm_arns"></a> [cloudwatch\_alarm\_arns](#output\_cloudwatch\_alarm\_arns) | ARNs of CloudWatch alarms created for EFS monitoring. |
| <a name="output_cloudwatch_alarm_sns_topic_arn"></a> [cloudwatch\_alarm\_sns\_topic\_arn](#output\_cloudwatch\_alarm\_sns\_topic\_arn) | ARN of the SNS topic used for CloudWatch alarm notifications. |
| <a name="output_cloudwatch_dashboard_url"></a> [cloudwatch\_dashboard\_url](#output\_cloudwatch\_dashboard\_url) | URL to the CloudWatch dashboard for monitoring PyPI server metrics. |
| <a name="output_ecs_cluster_name"></a> [ecs\_cluster\_name](#output\_ecs\_cluster\_name) | Name of the ECS cluster running the PyPI server. |
| <a name="output_ecs_service_arn"></a> [ecs\_service\_arn](#output\_ecs\_service\_arn) | ARN of the ECS service running the PyPI server. |
| <a name="output_ecs_service_name"></a> [ecs\_service\_name](#output\_ecs\_service\_name) | Name of the ECS service running the PyPI server. |
| <a name="output_pypi_load_balancer_arn"></a> [pypi\_load\_balancer\_arn](#output\_pypi\_load\_balancer\_arn) | ARN of the PyPI server load balancer. |
| <a name="output_pypi_password"></a> [pypi\_password](#output\_pypi\_password) | Password to access PyPI server. |
| <a name="output_pypi_server_urls"></a> [pypi\_server\_urls](#output\_pypi\_server\_urls) | List of PyPI server URLs. |
| <a name="output_pypi_user_secret"></a> [pypi\_user\_secret](#output\_pypi\_user\_secret) | AWS secret that stores PyPI username/password |
| <a name="output_pypi_user_secret_arn"></a> [pypi\_user\_secret\_arn](#output\_pypi\_user\_secret\_arn) | AWS secret ARN that stores PyPI username/password |
| <a name="output_pypi_username"></a> [pypi\_username](#output\_pypi\_username) | Username to access PyPI server. |
| <a name="output_task_min_count"></a> [task\_min\_count](#output\_task\_min\_count) | Actual task\_min\_count used (auto-calculated if var.task\_min\_count is null). |
<!-- END_TF_DOCS -->
