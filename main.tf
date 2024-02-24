locals {
  container_port = "8080"
}
module "pypiserver" {
  source  = "infrahouse/ecs/aws"
  version = "~> 2.6"
  providers = {
    aws     = aws
    aws.dns = aws.dns
  }
  alb_healthcheck_path          = "/"
  asg_subnets                   = var.asg_subnets
  asg_min_size                  = 1
  asg_max_size                  = 1
  asg_instance_type             = var.asg_instance_type
  dns_names                     = var.dns_names
  docker_image                  = "pypiserver/pypiserver:latest"
  internet_gateway_id           = var.internet_gateway_id
  load_balancer_subnets         = var.load_balancer_subnets
  service_name                  = "pypiserver"
  ssh_key_name                  = var.ssh_key_name
  zone_id                       = var.zone_id
  container_healthcheck_command = "/usr/local/bin/python -c \"import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.connect(('127.0.0.1', ${local.container_port}))\" || exit 1"
  container_command = [
    "run", "-p", local.container_port, "--server", "gunicorn", "--authenticate", "download,list,update", "-P", "/data/.htpasswd"
  ]
  task_local_volumes = {
    "htpasswd" : {
      host_path : "/etc/htpasswd"
      container_path : "/data/.htpasswd"
    }
  }
  task_efs_volumes = {
    "packages" : {
      file_system_id : aws_efs_file_system.packages.id
      container_path : "/data/packages"
    }
  }
  extra_files = [
    {
      content = format(
        "%s:%s",
        jsondecode(aws_secretsmanager_secret_version.pypiserver_secret.secret_string)["username"],
        jsondecode(aws_secretsmanager_secret_version.pypiserver_secret.secret_string)["bcrypt_hash"]
      )
      path        = "/etc/htpasswd"
      permissions = "644"
    }
  ]
}
