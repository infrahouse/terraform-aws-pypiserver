# terraform-aws-pypiserver
The module creates a private [PyPI server](https://github.com/pypiserver/pypiserver)

> **Note**: The VPC must set `enable_dns_hostnames` and  `enable_dns_support` to true.

## Usage

```hcl
module "pypiserver" {
  source  = "infrahouse/pypiserver/aws"
  version = "~> 1.0"
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
terraform-docs markdown .
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
| <a name="module_pypiserver"></a> [pypiserver](#module\_pypiserver) | infrahouse/ecs/aws | 3.1.1 |
| <a name="module_pypiserver_secret"></a> [pypiserver\_secret](#module\_pypiserver\_secret) | registry.infrahouse.com/infrahouse/secret/aws | 0.5.0 |

## Resources

| Name | Type |
|------|------|
| [aws_efs_file_system.packages](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.packages](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_security_group.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.efs_icmp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_password.password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_pet.username](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route53_zone.zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_subnet.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_asg_instance_type"></a> [asg\_instance\_type](#input\_asg\_instance\_type) | EC2 instances type | `string` | `"t3.micro"` | no |
| <a name="input_asg_subnets"></a> [asg\_subnets](#input\_asg\_subnets) | Auto Scaling Group Subnets. | `list(string)` | n/a | yes |
| <a name="input_dns_names"></a> [dns\_names](#input\_dns\_names) | List of hostnames the module will create in var.zone\_id. | `list(string)` | <pre>[<br>  "pypiserver"<br>]</pre> | no |
| <a name="input_internet_gateway_id"></a> [internet\_gateway\_id](#input\_internet\_gateway\_id) | Internet gateway id. Usually created by 'infrahouse/service-network/aws' | `string` | n/a | yes |
| <a name="input_load_balancer_subnets"></a> [load\_balancer\_subnets](#input\_load\_balancer\_subnets) | Load Balancer Subnets. | `list(string)` | n/a | yes |
| <a name="input_secret_readers"></a> [secret\_readers](#input\_secret\_readers) | List of role ARNs that will have read permissions of the PyPI secret. | `list(string)` | `null` | no |
| <a name="input_ssh_key_name"></a> [ssh\_key\_name](#input\_ssh\_key\_name) | ssh key name installed in ECS host instances. | `string` | n/a | yes |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Zone where DNS records will be created for the service and certificate validation. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_pypi_password"></a> [pypi\_password](#output\_pypi\_password) | Password to access PyPI server. |
| <a name="output_pypi_server_urls"></a> [pypi\_server\_urls](#output\_pypi\_server\_urls) | List of PyPI server URLs. |
| <a name="output_pypi_user_secret"></a> [pypi\_user\_secret](#output\_pypi\_user\_secret) | AWS secret that stores PyPI username/password |
| <a name="output_pypi_user_secret_arn"></a> [pypi\_user\_secret\_arn](#output\_pypi\_user\_secret\_arn) | AWS secret ARN that stores PyPI username/password |
| <a name="output_pypi_username"></a> [pypi\_username](#output\_pypi\_username) | Username to access PyPI server. |
