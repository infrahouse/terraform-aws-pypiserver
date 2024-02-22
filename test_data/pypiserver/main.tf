module "pypiserver" {
  source = "../../"
  providers = {
    aws     = aws
    aws.dns = aws
  }
  asg_subnets           = var.subnet_private_ids
  internet_gateway_id   = var.internet_gateway_id
  load_balancer_subnets = var.subnet_public_ids
  ssh_key_name          = aws_key_pair.test.key_name
  zone_id               = data.aws_route53_zone.test_zone.zone_id
}
