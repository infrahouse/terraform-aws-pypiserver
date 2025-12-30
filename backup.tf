# IAM role for AWS Backup service
data "aws_iam_policy_document" "backup_assume_role" {
  count = var.enable_efs_backup ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "backup" {
  count              = var.enable_efs_backup ? 1 : 0
  name_prefix        = "${var.service_name}-backup-"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role[0].json

  tags = local.default_module_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.enable_efs_backup ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  count      = var.enable_efs_backup ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Backup vault
resource "aws_backup_vault" "efs" {
  count         = var.enable_efs_backup ? 1 : 0
  name          = "${var.service_name}-efs-backup"
  force_destroy = var.backups_force_destroy

  tags = merge(
    {
      Name = "${var.service_name}-efs-backup-vault"
    },
    local.default_module_tags
  )
}

# Backup plan
resource "aws_backup_plan" "efs" {
  count = var.enable_efs_backup ? 1 : 0
  name  = "${var.service_name}-efs-backup-plan"

  rule {
    rule_name         = "daily_backup"
    target_vault_name = aws_backup_vault.efs[0].name
    schedule          = var.backup_schedule

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }

  tags = merge(
    {
      Name = "${var.service_name}-efs-backup-plan"
    },
    local.default_module_tags
  )
}

# Backup selection
resource "aws_backup_selection" "efs" {
  count        = var.enable_efs_backup ? 1 : 0
  iam_role_arn = aws_iam_role.backup[0].arn
  name         = "${var.service_name}-efs-backup-selection"
  plan_id      = aws_backup_plan.efs[0].id

  resources = [
    aws_efs_file_system.packages-enc.arn
  ]
}