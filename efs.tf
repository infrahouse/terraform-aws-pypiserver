resource "aws_efs_file_system" "packages" {
  creation_token = "pypi-packages"
  tags = merge(
    {
      Name = "pypi-packages"
    },
    local.default_module_tags
  )
}

resource "aws_efs_mount_target" "packages" {
  for_each       = toset(var.asg_subnets)
  file_system_id = aws_efs_file_system.packages.id
  subnet_id      = each.key
  security_groups = [
    aws_security_group.efs.id
  ]
}
