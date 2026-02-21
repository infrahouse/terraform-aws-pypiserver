locals {
  module_version = "2.1.0"

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

  # Gunicorn worker count
  # Use provided value or auto-calculate based on container memory
  gunicorn_workers = var.gunicorn_workers != null ? (
    var.gunicorn_workers
  ) : max(2, min(8, floor(var.container_memory / 128)))

  # Container CPU reservation
  # Calculate based on gunicorn workers to prevent CPU overloading
  # Formula: (workers × cpu_per_worker) + base_overhead
  # With 4 workers: (4 × 150) + 40 = 640 CPU units per task
  # Examples:
  #   - t3.small (2 vCPU = 2048 units): fits 3 tasks (640×3=1920, +128 system overhead)
  #   - c6a.xlarge (4 vCPU = 4096 units): fits 6 tasks (640×6=3840, +128 system overhead)
  container_cpu = var.container_cpu != null ? (
    var.container_cpu
  ) : (local.gunicorn_workers * 150) + 40

  # Cross-variable validation for EFS throughput
  # Provisioned mode requires an explicit throughput value
  validate_efs_throughput = (
    var.efs_throughput_mode == "provisioned" &&
    var.efs_provisioned_throughput_in_mibps == null ?
    tobool(
      "ERROR: efs_provisioned_throughput_in_mibps is required"
    ) :
    true
  )

  # EFS provisioned throughput — only meaningful in "provisioned" mode
  efs_provisioned_throughput = (
    var.efs_throughput_mode == "provisioned"
    ? var.efs_provisioned_throughput_in_mibps
    : null
  )

}
