resource "aws_efs_file_system" "packages-enc" {
  creation_token = "pypi-packages-encrypted"
  encrypted      = true
  kms_key_id     = data.aws_kms_key.efs_default.arn
  protection {
   replication_overwrite = "DISABLED"
  }
  tags = merge(
    {
      Name = "pypi-packages-encrypted"
    },
    local.default_module_tags
  )
}

resource "aws_efs_mount_target" "packages" {
  for_each       = toset(var.asg_subnets)
  file_system_id = aws_efs_file_system.packages-enc.id
  subnet_id      = each.key
  security_groups = [
    aws_security_group.efs.id
  ]
}
