locals {
  container_port = "8080"
}
module "pypiserver" {
  source  = "registry.infrahouse.com/infrahouse/ecs/aws"
  version = "6.1.0"
  providers = {
    aws     = aws
    aws.dns = aws.dns
  }
  healthcheck_path         = "/"
  environment              = var.environment
  asg_subnets              = var.asg_subnets
  asg_min_size             = var.asg_min_size
  asg_max_size             = var.asg_max_size
  task_min_count           = var.task_min_count
  task_max_count           = var.task_max_count
  ami_id                   = var.ami_id
  asg_instance_type        = var.asg_instance_type
  dns_names                = var.dns_names
  docker_image             = "pypiserver/pypiserver:${var.docker_image_tag}"
  internet_gateway_id      = data.aws_internet_gateway.selected.id
  load_balancer_subnets    = var.load_balancer_subnets
  service_name             = var.service_name
  zone_id                  = var.zone_id
  cloudinit_extra_commands = var.cloudinit_extra_commands
  enable_cloudwatch_logs   = true

  extra_instance_profile_permissions = var.extra_instance_profile_permissions

  container_healthcheck_command = "/usr/local/bin/python /data/healthcheck.py"
  # Using --backend simple-dir to disable caching. This prevents a cache synchronization
  # bug where different gunicorn workers across EFS-backed containers serve stale package
  # lists due to unreliable inotify events on NFS. See: pypiserver GitHub issue #449
  # For more details, see .claude/architecture-notes.md
  container_command = [
    "run", "-p", local.container_port, "--server", "gunicorn", "--backend", "simple-dir", "--authenticate", "download,list,update", "-P", "/data/.htpasswd"
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
  }
  task_efs_volumes = {
    "packages" : {
      file_system_id : aws_efs_file_system.packages-enc.id
      container_path : "/data/packages"
    }
  }
  extra_files = [
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
    }
  ]
  users                    = var.users
  access_log_force_destroy = var.access_log_force_destroy
}
