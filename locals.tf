locals {
  module_version = "1.11.0"

  module_name = "infrahouse/pypiserver/aws"
  default_module_tags = {
    environment : var.environment
    service : var.service_name
    account : data.aws_caller_identity.current.account_id
    created_by_module : local.module_name
  }

  # Cross-variable validation for ASG sizing
  # Validates that asg_min_size <= asg_max_size when both are set
  validate_asg_sizing = (
    var.asg_min_size != null && var.asg_max_size != null ?
    var.asg_min_size <= var.asg_max_size ?
    true :
    tobool("ERROR: asg_min_size (${var.asg_min_size}) must be less than or equal to asg_max_size (${var.asg_max_size})") :
    true
  )

}
