data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "zone" {
  zone_id = var.zone_id
}

data "aws_subnet" "selected" {
  id = var.asg_subnets[0]
}

data "aws_vpc" "selected" {
  id = data.aws_subnet.selected.vpc_id
}
