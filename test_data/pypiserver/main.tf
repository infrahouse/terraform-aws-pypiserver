module "pypiserver" {
  source = "../../"
  providers = {
    aws     = aws
    aws.dns = aws
  }
  asg_subnets           = var.subnet_private_ids
  load_balancer_subnets = var.subnet_public_ids
  zone_id               = var.zone_id

  access_log_force_destroy = true
  alarm_emails = [
    "aleks+terraform-aws-pypiserver@example.com"
  ]
}
