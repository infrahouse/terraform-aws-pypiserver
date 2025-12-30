resource "aws_security_group" "efs" {
  description = "Security group for pypiserver EFS volume"
  name_prefix = var.dns_names[0]
  vpc_id      = data.aws_subnet.selected.vpc_id

  tags = merge(
    {
      Name : "pypiserver EFS"
    },
    local.default_module_tags
  )
}

resource "aws_vpc_security_group_ingress_rule" "efs" {
  description       = "Allow NFS traffic to EFS volume"
  security_group_id = aws_security_group.efs.id
  from_port         = 2049
  to_port           = 2049
  ip_protocol       = "tcp"
  cidr_ipv4         = data.aws_vpc.selected.cidr_block
  tags = merge(
    {
      Name = "NFS traffic"
    },
    local.default_module_tags
  )
}

resource "aws_vpc_security_group_ingress_rule" "efs_icmp" {
  description       = "Allow ICMP traffic from VPC"
  security_group_id = aws_security_group.efs.id
  from_port         = -1
  to_port           = -1
  ip_protocol       = "icmp"
  cidr_ipv4         = data.aws_vpc.selected.cidr_block
  tags = merge(
    {
      Name = "ICMP traffic"
    },
    local.default_module_tags
  )
}
