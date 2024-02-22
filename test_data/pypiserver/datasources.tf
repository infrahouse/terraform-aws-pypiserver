data "aws_caller_identity" "this" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_route53_zone" "test_zone" {
  name = var.zone_name
}