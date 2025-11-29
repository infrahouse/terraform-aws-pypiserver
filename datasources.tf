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

# Internet Gateway Auto-Discovery
# Limitation: This module assumes a standard VPC configuration with exactly one Internet Gateway.
# AWS best practice is one IGW per VPC, which covers 99%+ of use cases.
# If the VPC has multiple IGWs (non-standard configuration), this data source will select
# the first matching IGW, which may lead to unexpected routing behavior.
data "aws_internet_gateway" "selected" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

data "aws_kms_key" "efs_default" {
  key_id = "alias/aws/elasticfilesystem"
}
