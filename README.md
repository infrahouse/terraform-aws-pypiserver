# terraform-aws-pypiserver
The module creates a private [PyPI server](https://github.com/pypiserver/pypiserver)

> **Note**: The VPC must set `enable_dns_hostnames` and  `enable_dns_support` to true.

## Usage

```hcl
module "pypiserver" {
  source  = "infrahouse/pypiserver/aws"
  version = "1.11.0"
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
```
<!-- BEGIN_TF_DOCS -->

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.11 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.11 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.6 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_pypiserver"></a> [pypiserver](#module\_pypiserver) | registry.infrahouse.com/infrahouse/ecs/aws | 6.1.0 |
| <a name="module_pypiserver_secret"></a> [pypiserver\_secret](#module\_pypiserver\_secret) | registry.infrahouse.com/infrahouse/secret/aws | 1.1.1 |

## Resources

| Name | Type |
|------|------|
| [aws_efs_file_system.packages-enc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.packages-enc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_security_group.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.efs_icmp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_password.password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_pet.username](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_internet_gateway.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/internet_gateway) | data source |
| [aws_kms_key.efs_default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_key) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route53_zone.zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_subnet.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_log_force_destroy"></a> [access\_log\_force\_destroy](#input\_access\_log\_force\_destroy) | Force destroy the S3 bucket containing access logs even if it's not empty.<br/>Should be set to true in test environments to allow clean teardown. | `bool` | `false` | no |
| <a name="input_ami_id"></a> [ami\_id](#input\_ami\_id) | AMI ID for EC2 instances in the Auto Scaling Group.<br/>If not specified, the latest Amazon Linux 2023 image will be used. | `string` | `null` | no |
| <a name="input_asg_instance_type"></a> [asg\_instance\_type](#input\_asg\_instance\_type) | EC2 instance type for Auto Scaling Group instances.<br/>Must be a valid AWS instance type. | `string` | `"t3.micro"` | no |
| <a name="input_asg_max_size"></a> [asg\_max\_size](#input\_asg\_max\_size) | Maximum number of instances in Auto Scaling Group.<br/>If null, calculated based on number of tasks and their memory requirements. | `number` | `null` | no |
| <a name="input_asg_min_size"></a> [asg\_min\_size](#input\_asg\_min\_size) | Minimum number of instances in Auto Scaling Group.<br/>If null, defaults to the number of subnets. | `number` | `null` | no |
| <a name="input_asg_subnets"></a> [asg\_subnets](#input\_asg\_subnets) | List of subnet IDs where Auto Scaling Group instances will be launched.<br/>Must contain at least one subnet. | `list(string)` | n/a | yes |
| <a name="input_cloudinit_extra_commands"></a> [cloudinit\_extra\_commands](#input\_cloudinit\_extra\_commands) | Additional cloud-init commands to execute during ASG instance initialization.<br/>Commands are run after the default setup. | `list(string)` | `[]` | no |
| <a name="input_dns_names"></a> [dns\_names](#input\_dns\_names) | List of DNS hostnames to create in the specified Route53 zone.<br/>These will be A records pointing to the load balancer. | `list(string)` | <pre>[<br/>  "pypiserver"<br/>]</pre> | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name used for resource tagging and naming.<br/>Examples: development, staging, production. | `string` | `"development"` | no |
| <a name="input_extra_instance_profile_permissions"></a> [extra\_instance\_profile\_permissions](#input\_extra\_instance\_profile\_permissions) | Additional IAM policy document in JSON format to attach to the ASG instance profile.<br/>Useful for granting access to S3, DynamoDB, etc. | `string` | `null` | no |
| <a name="input_load_balancer_subnets"></a> [load\_balancer\_subnets](#input\_load\_balancer\_subnets) | List of subnet IDs where the Application Load Balancer will be placed.<br/>Must be in different Availability Zones for high availability. | `list(string)` | n/a | yes |
| <a name="input_secret_readers"></a> [secret\_readers](#input\_secret\_readers) | List of IAM role ARNs that will have read permissions for the PyPI authentication secret.<br/>The secret is stored in AWS Secrets Manager. | `list(string)` | `null` | no |
| <a name="input_service_name"></a> [service\_name](#input\_service\_name) | Name of the PyPI service.<br/>Used for resource naming and tagging throughout the module. | `string` | `"pypiserver"` | no |
| <a name="input_task_max_count"></a> [task\_max\_count](#input\_task\_max\_count) | Maximum number of ECS tasks to run.<br/>Used for auto-scaling the PyPI service. | `number` | `10` | no |
| <a name="input_task_min_count"></a> [task\_min\_count](#input\_task\_min\_count) | Minimum number of ECS tasks to run.<br/>Used for auto-scaling the PyPI service. | `number` | `2` | no |
| <a name="input_users"></a> [users](#input\_users) | A list of maps with user definitions according to the cloud-init format.<br/>See https://cloudinit.readthedocs.io/en/latest/reference/examples.html#including-users-and-groups<br/>for field descriptions and examples. | <pre>list(<br/>    object(<br/>      {<br/>        name                = string<br/>        expiredate          = optional(string)<br/>        gecos               = optional(string)<br/>        homedir             = optional(string)<br/>        primary_group       = optional(string)<br/>        groups              = optional(string) # Comma separated list of strings e.g. "users,admin"<br/>        selinux_user        = optional(string)<br/>        lock_passwd         = optional(bool)<br/>        inactive            = optional(number)<br/>        passwd              = optional(string)<br/>        no_create_home      = optional(bool)<br/>        no_user_group       = optional(bool)<br/>        no_log_init         = optional(bool)<br/>        ssh_import_id       = optional(list(string))<br/>        ssh_authorized_keys = optional(list(string))<br/>        sudo                = optional(any) # Can be false or a list of strings e.g. ["ALL=(ALL) NOPASSWD:ALL"]<br/>        system              = optional(bool)<br/>        snapuser            = optional(string)<br/>      }<br/>    )<br/>  )</pre> | `[]` | no |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route53 hosted zone ID where DNS records will be created.<br/>Used for the service endpoint and certificate validation. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_pypi_load_balancer_arn"></a> [pypi\_load\_balancer\_arn](#output\_pypi\_load\_balancer\_arn) | ARN of the PyPI server load balancer. |
| <a name="output_pypi_password"></a> [pypi\_password](#output\_pypi\_password) | Password to access PyPI server. |
| <a name="output_pypi_server_urls"></a> [pypi\_server\_urls](#output\_pypi\_server\_urls) | List of PyPI server URLs. |
| <a name="output_pypi_user_secret"></a> [pypi\_user\_secret](#output\_pypi\_user\_secret) | AWS secret that stores PyPI username/password |
| <a name="output_pypi_user_secret_arn"></a> [pypi\_user\_secret\_arn](#output\_pypi\_user\_secret\_arn) | AWS secret ARN that stores PyPI username/password |
| <a name="output_pypi_username"></a> [pypi\_username](#output\_pypi\_username) | Username to access PyPI server. |
<!-- END_TF_DOCS -->
