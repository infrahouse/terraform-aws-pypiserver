resource "aws_efs_file_system" "packages" {
  creation_token = "pypi-packages"
  tags = {
    Name = "pypi-packages"
  }
}

resource "aws_efs_mount_target" "packages" {
  for_each       = toset(var.asg_subnets)
  file_system_id = aws_efs_file_system.packages.id
  subnet_id      = each.key
}
