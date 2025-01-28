locals {
  module_name = "infrahouse/pypiserver/aws"
  default_module_tags = {
    environment : var.environment
    service : var.service_name
    account : data.aws_caller_identity.current.account_id
    created_by_module : local.module_name
  }

}