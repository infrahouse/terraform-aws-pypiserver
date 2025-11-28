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
    Must be a valid AWS instance type.
  EOT
  type        = string
  default     = "t3.micro"

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
    condition     = var.asg_min_size == null || var.asg_min_size >= 0
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
    condition     = var.asg_max_size == null || var.asg_max_size > 0
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
    condition = var.secret_readers == null || alltrue([
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
  EOT
  type        = number
  default     = 10

  validation {
    condition     = var.task_max_count > 0
    error_message = "Maximum task count must be greater than 0."
  }
}

variable "task_min_count" {
  description = <<-EOT
    Minimum number of ECS tasks to run.
    Used for auto-scaling the PyPI service.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.task_min_count >= 0
    error_message = "Minimum task count must be >= 0."
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

variable "access_log_force_destroy" {
  description = <<-EOT
    Force destroy the S3 bucket containing access logs even if it's not empty.
    Should be set to true in test environments to allow clean teardown.
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
