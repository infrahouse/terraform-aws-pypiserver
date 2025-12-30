locals {
  container_port = "8080"

  # System and page cache overhead (MB)
  system_overhead_mb = 300 # ECS agent, CloudWatch, OS
  page_cache_mb      = 500 # Minimum for EFS metadata caching with --backend simple-dir

  # Total overhead
  total_overhead_mb = local.system_overhead_mb + local.page_cache_mb

  # Get instance RAM from AWS (in MiB)
  instance_total_ram_mb = data.aws_ec2_instance_type.selected.memory_size

  # Available RAM for containers per instance
  available_ram_mb = local.instance_total_ram_mb - local.total_overhead_mb

  # Calculate container memory reservation (75% of hard limit if not specified)
  container_memory_reservation_actual = var.container_memory_reservation != null ? (
    var.container_memory_reservation
  ) : floor(var.container_memory * 0.75)

  # Get instance vCPU count from AWS
  instance_vcpu_count = data.aws_ec2_instance_type.selected.default_vcpus

  # Total CPU units available per instance (1 vCPU = 1024 units)
  instance_total_cpu_units = local.instance_vcpu_count * 1024

  # Available CPU for containers (reserve ~128 units for system overhead)
  available_cpu_units = local.instance_total_cpu_units - 128

  # Calculate how many tasks can fit on ONE instance based on RAM
  tasks_per_instance_ram = max(1, floor(local.available_ram_mb / local.container_memory_reservation_actual))

  # Calculate how many tasks can fit on ONE instance based on CPU
  tasks_per_instance_cpu = max(1, floor(local.available_cpu_units / local.container_cpu))

  # Use the MINIMUM of RAM and CPU constraints (most restrictive wins)
  tasks_per_instance = min(local.tasks_per_instance_ram, local.tasks_per_instance_cpu)

  # Determine number of instances in ASG (defaults to number of subnets if not specified)
  asg_instance_count = var.asg_min_size != null ? var.asg_min_size : length(var.asg_subnets)

  # Auto-calculate task_min_count based on total cluster capacity
  # Formula: tasks_per_instance × number_of_instances
  # This ensures we fully utilize all instances in the ASG
  auto_task_min_count = local.tasks_per_instance * local.asg_instance_count

  # Use provided task_min_count or auto-calculated value
  task_min_count = var.task_min_count != null ? var.task_min_count : local.auto_task_min_count

  # Auto-calculate task_max_count as 2x min_count if not specified
  # This allows doubling capacity during traffic spikes or scaling events
  task_max_count = var.task_max_count != null ? var.task_max_count : (local.task_min_count * 2)
}
module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/ecs/aws"
  version = "7.1.0"
  providers = {
    aws     = aws
    aws.dns = aws.dns
  }
  healthcheck_path         = "/"
  environment              = var.environment
  asg_subnets              = var.asg_subnets
  asg_min_size             = var.asg_min_size
  asg_max_size             = var.asg_max_size
  task_min_count           = local.task_min_count
  task_max_count           = local.task_max_count
  ami_id                   = var.ami_id
  asg_instance_type        = var.asg_instance_type
  dns_names                = var.dns_names
  docker_image             = "pypiserver/pypiserver:${var.docker_image_tag}"
  load_balancer_subnets    = var.load_balancer_subnets
  service_name             = var.service_name
  zone_id                  = var.zone_id
  cloudinit_extra_commands = var.cloudinit_extra_commands
  enable_cloudwatch_logs   = true

  # Container resource limits
  container_memory             = var.container_memory
  container_memory_reservation = var.container_memory_reservation != null ? var.container_memory_reservation : floor(var.container_memory * 0.75)
  container_cpu                = local.container_cpu

  extra_instance_profile_permissions = var.extra_instance_profile_permissions

  container_healthcheck_command = "/usr/local/bin/python /data/healthcheck.py"
  # Using --backend simple-dir to disable caching. This prevents a cache synchronization
  # bug where different gunicorn workers across EFS-backed containers serve stale package
  # lists due to unreliable inotify events on NFS. See: pypiserver GitHub issue #449
  # For more details, see .claude/architecture-notes.md
  container_command = [
    "run", "-p", local.container_port,
    "--server", "gunicorn", "--backend", "simple-dir",
    "--authenticate", "download,list,update", "-P", "/data/.htpasswd"
  ]
  task_local_volumes = {
    "htpasswd" : {
      host_path : "/etc/htpasswd"
      container_path : "/data/.htpasswd"
    }
    "healthcheck" : {
      host_path : "/opt/pypiserver/healthcheck.py"
      container_path : "/data/healthcheck.py"
    }
    "gunicorn_config" : {
      host_path : "/opt/pypiserver/gunicorn.conf.py"
      container_path : "/data/gunicorn.conf.py"
    }
  }
  task_environment_variables = [
    {
      name  = "GUNICORN_WORKERS"
      value = tostring(local.gunicorn_workers)
    }
  ]
  task_efs_volumes = {
    "packages" : {
      file_system_id : aws_efs_file_system.packages-enc.id
      container_path : "/data/packages"
    }
  }
  extra_files = concat(
    [
      {
        content = format(
          "%s:%s",
          jsondecode(module.pypiserver_secret.secret_value)["username"],
          jsondecode(module.pypiserver_secret.secret_value)["bcrypt_hash"]
        )
        path        = "/etc/htpasswd"
        permissions = "644"
      },
      {
        content     = file("${path.module}/files/healthcheck.py")
        path        = "/opt/pypiserver/healthcheck.py"
        permissions = "755"
      },
      {
        content     = file("${path.module}/files/gunicorn.conf.py")
        path        = "/opt/pypiserver/gunicorn.conf.py"
        permissions = "644"
      }
    ],
    var.extra_files
  )
  users                    = var.users
  access_log_force_destroy = var.access_log_force_destroy
  alarm_emails             = var.alarm_emails
}
