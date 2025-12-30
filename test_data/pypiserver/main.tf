module "pypiserver" {
  source = "../../"
  providers = {
    aws     = aws
    aws.dns = aws
  }
  asg_subnets           = var.subnet_private_ids
  load_balancer_subnets = var.subnet_public_ids
  zone_id               = var.zone_id

  # Infrastructure sizing - optimized for <1% error rate under burst load
  # Strategy: Fewer, beefier instances to reduce ALB target variance under burst traffic
  # 2 × c6a.xlarge (4 vCPU each, compute-optimized) = 8 total vCPUs
  # 2 instances × 6 tasks/instance × 4 workers/task = 48 total workers
  # 510 concurrent requests / 48 workers = 10.6 req/worker (manageable)
  # Only 6 ALB targets (vs 12 with t3.small) = less distribution variance
  asg_instance_type = "c6a.xlarge"
  asg_min_size      = 2
  asg_max_size      = 4

  # Container resources
  container_memory = 512

  # Worker configuration - override auto-calc to get more capacity
  # Auto-calc would give 4 workers, but 6 provides better burst handling
  # note: test with 4 workers had lower error rate
  # gunicorn_workers = 6

  # Task scaling - now auto-calculates based on BOTH CPU and RAM constraints
  # c6a.xlarge: min(RAM: 19 tasks, CPU: 6 tasks) = 6 tasks/instance
  # 2 instances × 6 tasks = 12 min tasks, 24 max tasks (2× scaling capacity)
  task_min_count = null # Auto = min(RAM limit, CPU limit) × instances = 12
  task_max_count = null # Auto = 2 × task_min_count = 24

  access_log_force_destroy = true
  backups_force_destroy    = true
  alarm_emails = [
    "aleks+terraform-aws-pypiserver@example.com"
  ]

  # Install diagnostic tools for stress testing and incident investigation
  cloudinit_extra_commands = [
    "yum install -y sysstat jq lsof psmisc net-tools"
  ]

  # Deploy diagnostic collection script
  extra_files = [
    {
      content     = file("${path.module}/files/collect-diagnostics.sh")
      path        = "/opt/pypiserver/collect-diagnostics.sh"
      permissions = "755"
    }
  ]
}
