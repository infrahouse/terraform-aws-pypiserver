module "service-network" {
  source                = "infrahouse/service-network/aws"
  version               = "~> 2.3"
  service_name          = "pypiserver"
  vpc_cidr_block        = "10.1.0.0/16"
  management_cidr_block = "10.1.0.0/16"
  enable_dns_hostnames  = true
  enable_dns_support    = true
  restrict_all_traffic  = true
  subnets = [
    {
      cidr                    = "10.1.0.0/24"
      availability-zone       = data.aws_availability_zones.available.names[0]
      map_public_ip_on_launch = true
      create_nat              = true
      forward_to              = null
    },
    {
      cidr                    = "10.1.1.0/24"
      availability-zone       = data.aws_availability_zones.available.names[1]
      map_public_ip_on_launch = true
      create_nat              = true
      forward_to              = null
    },
    {
      cidr                    = "10.1.2.0/24"
      availability-zone       = data.aws_availability_zones.available.names[0]
      map_public_ip_on_launch = false
      create_nat              = false
      forward_to              = "10.1.0.0/24"
    },
    {
      cidr                    = "10.1.3.0/24"
      availability-zone       = data.aws_availability_zones.available.names[1]
      map_public_ip_on_launch = false
      create_nat              = false
      forward_to              = "10.1.1.0/24"
    }
  ]
}
