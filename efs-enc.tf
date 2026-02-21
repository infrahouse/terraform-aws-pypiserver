resource "aws_efs_file_system" "packages-enc" {
  creation_token                  = "pypi-packages-encrypted"
  encrypted                       = true
  kms_key_id                      = data.aws_kms_key.efs_default.arn
  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = local.efs_provisioned_throughput

  dynamic "lifecycle_policy" {
    for_each = var.efs_lifecycle_policy != null ? [1] : []
    content {
      transition_to_ia = "AFTER_${var.efs_lifecycle_policy}_DAYS"
    }
  }

  tags = merge(
    {
      Name           = "pypi-packages-encrypted"
      module_version = local.module_version
    },
    local.default_module_tags
  )
}

resource "aws_efs_mount_target" "packages-enc" {
  for_each       = toset(var.asg_subnets)
  file_system_id = aws_efs_file_system.packages-enc.id
  subnet_id      = each.key
  security_groups = [
    aws_security_group.efs.id
  ]
}
