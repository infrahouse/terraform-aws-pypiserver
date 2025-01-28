variable "asg_instance_type" {
  description = "EC2 instances type"
  type        = string
  default     = "t3.micro"
}
variable "asg_subnets" {
  description = "Auto Scaling Group Subnets."
  type        = list(string)
}

variable "dns_names" {
  description = "List of hostnames the module will create in var.zone_id."
  type        = list(string)
  default     = ["pypiserver"]
}

variable "environment" {
  description = "Name of environment."
  type        = string
  default     = "development"
}

variable "internet_gateway_id" {
  description = "Internet gateway id. Usually created by 'infrahouse/service-network/aws'"
  type        = string
}

variable "load_balancer_subnets" {
  description = "Load Balancer Subnets."
  type        = list(string)
}

variable "secret_readers" {
  description = "List of role ARNs that will have read permissions of the PyPI secret."
  default     = null
  type        = list(string)
}

variable "service_name" {
  description = "Service name."
  type        = string
  default     = "pypiserver"
}

variable "ssh_key_name" {
  description = "ssh key name installed in ECS host instances."
  type        = string
}

variable "zone_id" {
  description = "Zone where DNS records will be created for the service and certificate validation."
  type        = string
}

