variable "ami_id" {
  description = <<-EOT
    AMI ID for EC2 instances in the Auto Scaling Group.
    If not specified, the latest Amazon Linux 2023 image will be used.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[a-f0-9]{8,}$", var.ami_id))
    error_message = "AMI ID must be in the format 'ami-xxxxxxxxx' or null."
  }
}

variable "asg_instance_type" {
  description = <<-EOT
    EC2 instance type for Auto Scaling Group instances.

    The instance must have sufficient memory for:
    - Container allocation: container_memory × tasks_per_instance
    - Page cache: ~512 MB minimum (critical for EFS metadata caching with --backend simple-dir)
    - System overhead: ~300 MB (ECS agent, CloudWatch, OS)

    Minimum memory calculation:
      Required RAM = (container_memory × tasks_per_instance) + 512 MB + 300 MB

    Recommended instance types:
    - Light workload (< 50 packages): t3.micro (1 GB) with container_memory=256
    - Medium workload (50-200 packages): t3.small (2 GB) with container_memory=512 (default)
    - Heavy workload (200+ packages): t3.medium (4 GB) with container_memory=1024

    Using an instance that's too small will cause swap activity, leading to high iowait
    and degraded performance under load.
  EOT
  type        = string
  default     = "t3.small"

  validation {
    condition     = can(regex("^[a-z][0-9][a-z]?\\.[a-z0-9]+$", var.asg_instance_type))
    error_message = "Instance type must be a valid AWS instance type (e.g., t3.micro, m5.large)."
  }
}

variable "asg_min_size" {
  description = <<-EOT
    Minimum number of instances in Auto Scaling Group.
    If null, defaults to the number of subnets.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.asg_min_size == null ? true : var.asg_min_size >= 0
    error_message = "ASG minimum size must be >= 0 or null."
  }
}

variable "asg_max_size" {
  description = <<-EOT
    Maximum number of instances in Auto Scaling Group.
    If null, calculated based on number of tasks and their memory requirements.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.asg_max_size == null ? true : var.asg_max_size > 0
    error_message = "ASG maximum size must be > 0 or null."
  }
}

variable "asg_subnets" {
  description = <<-EOT
    List of subnet IDs where Auto Scaling Group instances will be launched.
    Must contain at least one subnet.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.asg_subnets) > 0
    error_message = "At least one subnet must be specified for the Auto Scaling Group."
  }

  validation {
    condition     = alltrue([for s in var.asg_subnets : can(regex("^subnet-[a-f0-9]{8,}$", s))])
    error_message = "All subnet IDs must be in the format 'subnet-xxxxxxxxx'."
  }
}

variable "dns_names" {
  description = <<-EOT
    List of DNS hostnames to create in the specified Route53 zone.
    These will be A records pointing to the load balancer.
  EOT
  type        = list(string)
  default     = ["pypiserver"]

  validation {
    condition     = length(var.dns_names) > 0
    error_message = "At least one DNS name must be specified."
  }

  validation {
    condition     = alltrue([for name in var.dns_names : can(regex("^[a-z0-9-]+$", name))])
    error_message = "DNS names must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = <<-EOT
    Environment name used for resource tagging and naming.
    Examples: development, staging, production.
  EOT
  type        = string
  default     = "development"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "Environment must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "load_balancer_subnets" {
  description = <<-EOT
    List of subnet IDs where the Application Load Balancer will be placed.
    Must be in different Availability Zones for high availability.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.load_balancer_subnets) >= 2
    error_message = "At least two subnets in different AZs must be specified for the load balancer."
  }

  validation {
    condition     = alltrue([for s in var.load_balancer_subnets : can(regex("^subnet-[a-f0-9]{8,}$", s))])
    error_message = "All subnet IDs must be in the format 'subnet-xxxxxxxxx'."
  }
}

variable "secret_readers" {
  description = <<-EOT
    List of IAM role ARNs that will have read permissions for the PyPI authentication secret.
    The secret is stored in AWS Secrets Manager.
  EOT
  type        = list(string)
  default     = null

  validation {
    condition = var.secret_readers == null ? true : alltrue([
      for arn in var.secret_readers : can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", arn))
    ])
    error_message = "All secret readers must be valid IAM role ARNs."
  }
}

variable "service_name" {
  description = <<-EOT
    Name of the PyPI service.
    Used for resource naming and tagging throughout the module.
  EOT
  type        = string
  default     = "pypiserver"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.service_name))
    error_message = "Service name must start with a letter, contain only lowercase letters, numbers, and hyphens, and end with a letter or number."
  }

  validation {
    condition     = length(var.service_name) <= 32
    error_message = "Service name must be 32 characters or less."
  }
}

variable "task_max_count" {
  description = <<-EOT
    Maximum number of ECS tasks to run.
    Used for auto-scaling the PyPI service.

    If null (default), automatically calculated as 2 × task_min_count to allow
    doubling capacity during traffic spikes or scaling events.

    Set explicitly to override auto-calculation for specific requirements.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.task_max_count == null ? true : var.task_max_count > 0
    error_message = "Maximum task count must be greater than 0 or null."
  }
}

variable "task_min_count" {
  description = <<-EOT
    Minimum number of ECS tasks to run across the entire cluster.

    If null (default), automatically calculated to maximize cluster utilization
    based on BOTH CPU and RAM constraints (whichever is more restrictive):

      tasks_per_instance_ram = floor(available_ram / container_memory_reservation)
      tasks_per_instance_cpu = floor(available_cpu / container_cpu)
      tasks_per_instance = min(tasks_per_instance_ram, tasks_per_instance_cpu)
      task_min_count = tasks_per_instance × number_of_instances

    Number of instances is determined by asg_min_size (or number of subnets if not specified).

    Example auto-calculations (with 2 instances, 512 MB containers, 640 CPU units):
      t3.small (2 vCPU, 2 GB):
        - RAM: floor(1248 MB / 384 MB) = 3 tasks
        - CPU: floor(1920 units / 640 units) = 3 tasks
        - Result: min(3, 3) × 2 = 6 tasks total (RAM and CPU balanced)

      c6a.xlarge (4 vCPU, 8 GB):
        - RAM: floor(7392 MB / 384 MB) = 19 tasks
        - CPU: floor(3968 units / 640 units) = 6 tasks
        - Result: min(19, 6) × 2 = 12 tasks total (CPU constrained)

    This ensures all instances in the ASG are fully utilized without exceeding resource limits.

    Set explicitly to override auto-calculation for specific requirements.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.task_min_count == null ? true : var.task_min_count >= 0
    error_message = "Minimum task count must be >= 0 or null."
  }
}

variable "users" {
  description = <<-EOT
    A list of maps with user definitions according to the cloud-init format.
    See https://cloudinit.readthedocs.io/en/latest/reference/examples.html#including-users-and-groups
    for field descriptions and examples.
  EOT
  type = list(
    object(
      {
        name                = string
        expiredate          = optional(string)
        gecos               = optional(string)
        homedir             = optional(string)
        primary_group       = optional(string)
        groups              = optional(string) # Comma separated list of strings e.g. "users,admin"
        selinux_user        = optional(string)
        lock_passwd         = optional(bool)
        inactive            = optional(number)
        passwd              = optional(string)
        no_create_home      = optional(bool)
        no_user_group       = optional(bool)
        no_log_init         = optional(bool)
        ssh_import_id       = optional(list(string))
        ssh_authorized_keys = optional(list(string))
        sudo                = optional(any) # Can be false or a list of strings e.g. ["ALL=(ALL) NOPASSWD:ALL"]
        system              = optional(bool)
        snapuser            = optional(string)
      }
    )
  )
  default = []

  validation {
    condition     = alltrue([for u in var.users : length(u.name) > 0])
    error_message = "Each user must have a non-empty 'name' field."
  }
}

variable "zone_id" {
  description = <<-EOT
    Route53 hosted zone ID where DNS records will be created.
    Used for the service endpoint and certificate validation.
  EOT
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.zone_id))
    error_message = "Zone ID must be a valid Route53 hosted zone ID (format: Z followed by alphanumeric characters)."
  }
}

variable "extra_instance_profile_permissions" {
  description = <<-EOT
    Additional IAM policy document in JSON format to attach to the ASG instance profile.
    Useful for granting access to S3, DynamoDB, etc.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.extra_instance_profile_permissions == null || can(jsondecode(var.extra_instance_profile_permissions))
    error_message = "Extra instance profile permissions must be valid JSON or null."
  }
}

variable "cloudinit_extra_commands" {
  description = <<-EOT
    Additional cloud-init commands to execute during ASG instance initialization.
    Commands are run after the default setup.
  EOT
  type        = list(string)
  default     = []
}

variable "extra_files" {
  description = <<-EOT
    Additional files to deploy to EC2 instances during initialization.
    Each file should have: content, path, and permissions.
    Example usage in calling module:
      extra_files = [
        {
          content     = file("$${path.module}/files/script.sh")
          path        = "/opt/scripts/script.sh"
          permissions = "755"
        }
      ]
  EOT
  type = list(
    object({
      content     = string
      path        = string
      permissions = string
    })
  )
  default = []

  validation {
    condition = alltrue([
      for f in var.extra_files : can(regex("^[0-7]{3,4}$", f.permissions))
    ])
    error_message = "File permissions must be valid octal format (e.g., '755', '644')."
  }

  validation {
    condition = alltrue([
      for f in var.extra_files : length(f.path) > 0 && can(regex("^/", f.path))
    ])
    error_message = "File path must be an absolute path starting with '/'."
  }
}

variable "access_log_force_destroy" {
  description = <<-EOT
    Force destroy the S3 bucket containing access logs even if it's not empty.
    Should be set to true in test environments to allow clean teardown.
  EOT
  type        = bool
  default     = false
}

variable "backups_force_destroy" {
  description = <<-EOT
    Force destroy the backup vault even if it contains recovery points.
    Should be set to true in test environments to allow clean teardown.
    WARNING: Setting this to true will delete all backups when destroying the vault.
  EOT
  type        = bool
  default     = false
}

variable "enable_efs_backup" {
  description = <<-EOT
    Enable AWS Backup for the EFS file system containing PyPI packages.
    When enabled, creates a backup vault, plan, and selection.
    Set to false in dev/test environments to reduce costs if backups are not needed.
  EOT
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = <<-EOT
    Number of days to retain EFS backups.
    Only used when enable_efs_backup is true.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days > 0 && var.backup_retention_days <= 35
    error_message = "Backup retention must be between 1 and 35 days."
  }
}

variable "backup_schedule" {
  description = <<-EOT
    Cron expression for backup schedule.
    Default is daily at 2 AM UTC: "cron(0 2 * * ? *)"
    Only used when enable_efs_backup is true.
  EOT
  type        = string
  default     = "cron(0 2 * * ? *)"

  validation {
    condition     = can(regex("^cron\\(", var.backup_schedule))
    error_message = "Backup schedule must be a valid cron expression starting with 'cron('."
  }
}

variable "efs_lifecycle_policy" {
  description = <<-EOT
    Number of days after which files are moved to EFS Infrequent Access storage class.
    Valid values: null (disabled), 7, 14, 30, 60, or 90 days.
    Moving old package versions to IA storage can reduce costs by up to 92%.
    Set to null to disable lifecycle policy.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.efs_lifecycle_policy == null || contains([7, 14, 30, 60, 90], var.efs_lifecycle_policy)
    error_message = "EFS lifecycle policy must be null or one of: 7, 14, 30, 60, 90 days."
  }
}

variable "docker_image_tag" {
  description = <<-EOT
    Docker image tag for PyPI server.
    Defaults to 'latest'. For production, pin to a specific version (e.g., 'v2.3.0').
    Available tags: https://hub.docker.com/r/pypiserver/pypiserver/tags
  EOT
  type        = string
  default     = "latest"

  validation {
    condition     = length(var.docker_image_tag) > 0
    error_message = "Docker image tag must not be empty."
  }
}

variable "alarm_emails" {
  description = <<-EOT
    List of email addresses to receive alarm notifications.
    AWS will send confirmation emails that must be accepted.
    At least one email is required for CloudWatch alarm notifications.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alarm_emails) > 0
    error_message = "At least one email address must be provided for alarm notifications."
  }

  validation {
    condition = alltrue(
      [
        for email in var.alarm_emails : can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", email))
      ]
    )
    error_message = "All email addresses must be valid email format."
  }
}

variable "alarm_topic_arns" {
  description = <<-EOT
    List of existing SNS topic ARNs to send alarms to.
    Useful for advanced integrations like PagerDuty, Slack, etc.
    These are in addition to the email notifications.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue(
      [
        for arn in var.alarm_topic_arns : can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:.+$", arn))
      ]
    )
    error_message = "All topic ARNs must be valid SNS topic ARNs."
  }
}

variable "efs_burst_credit_threshold" {
  description = <<-EOT
    Minimum EFS burst credit balance before triggering an alarm.
    EFS burst credits allow temporary higher throughput. Low credits can impact performance.
    Default: 1000000000000 (1 trillion bytes, approximately 1TB of burst capacity).
  EOT
  type        = number
  default     = 1000000000000

  validation {
    condition     = var.efs_burst_credit_threshold > 0
    error_message = "EFS burst credit threshold must be greater than 0."
  }
}

variable "container_memory" {
  description = <<-EOT
    Memory limit for the PyPI container in MB.
    This is the hard memory limit - the container will be killed if it exceeds this value.

    With --backend simple-dir, pypiserver scans directories on every request.
    More memory allows better page cache performance for EFS metadata.

    Recommended values:
    - Light workload (< 50 packages, < 5 users): 256 MB
    - Medium workload (50-200 packages, 5-20 users): 512 MB (default)
    - Heavy workload (200+ packages, 20+ users): 1024 MB

    Default: 512 MB (optimized for medium workloads)
    Minimum: 128 MB (only suitable for very light workloads)
  EOT
  type        = number
  default     = 512

  validation {
    condition     = var.container_memory >= 128
    error_message = "Container memory must be at least 128 MB."
  }

  validation {
    condition     = var.container_memory <= 30720
    error_message = "Container memory must not exceed 30720 MB (30 GB)."
  }
}

variable "container_memory_reservation" {
  description = <<-EOT
    Soft memory limit for the PyPI container in MB.
    This is the amount of memory reserved for the container on the host instance.
    The container can use more memory up to the container_memory limit.

    If null, defaults to 75% of container_memory to allow some burst capacity
    while preventing overcommitment of host resources.

    Set to a specific value if you want precise control over memory reservation.
    Set to 0 to disable soft limit (not recommended).
  EOT
  type        = number
  default     = null

  validation {
    condition = var.container_memory_reservation == null ? true : (
      var.container_memory_reservation >= 0 && var.container_memory_reservation <= 30720
    )
    error_message = "Container memory reservation must be between 0 and 30720 MB (30 GB) or null."
  }
}

variable "container_cpu" {
  description = <<-EOT
    CPU units to allocate to the PyPI container.
    1024 CPU units = 1 vCPU.

    If null (default), automatically calculated based on gunicorn workers:
      formula: (gunicorn_workers × 150) + 40

    This formula accounts for ~128 CPU units of system overhead (ECS agent, CloudWatch)
    and is calibrated to allow 3 pypiserver tasks per t3.small instance (2 vCPU),
    matching the memory-based limit.

    Examples with auto-calculation (on t3.small with 2048 CPU - 128 overhead = 1920 available):
      2 workers → 340 CPU units (~0.33 vCPU) → allows 5 tasks on t3.small
      4 workers → 640 CPU units (~0.62 vCPU) → allows 3 tasks on t3.small
      6 workers → 940 CPU units (~0.92 vCPU) → allows 2 tasks on t3.small

    Override this value to manually control CPU reservation for specific needs.
  EOT
  type        = number
  default     = null

  validation {
    condition = var.container_cpu == null ? true : (
      var.container_cpu >= 128 && var.container_cpu <= 4096
    )
    error_message = "Container CPU must be between 128 and 4096 CPU units or null for auto-calculation."
  }
}

variable "gunicorn_workers" {
  description = <<-EOT
    Number of gunicorn workers per container.

    If null (default), automatically calculated based on container memory:
      formula: max(2, min(8, floor(container_memory / 128)))

    Examples with auto-calculation:
      256 MB  → 2 workers
      512 MB  → 4 workers
      768 MB  → 6 workers
      1024 MB → 8 workers

    Override this value to tune for specific workload patterns:
    - More workers = higher request capacity but more EFS directory scan contention
    - Fewer workers = lower capacity but less EFS contention

    With --backend simple-dir, each request scans the packages directory on EFS.
    If experiencing high latency during bursts, consider reducing worker count
    or switching to a caching backend.

    Minimum: 1 worker (not recommended for production)
    Maximum: 16 workers (gevent can handle many concurrent connections per worker)

    Default: null (auto-calculated from container_memory)
  EOT
  type        = number
  default     = null

  validation {
    condition = var.gunicorn_workers == null ? true : (
      var.gunicorn_workers >= 1 && var.gunicorn_workers <= 16
    )
    error_message = "Gunicorn workers must be between 1 and 16 or null for auto-calculation."
  }
}
