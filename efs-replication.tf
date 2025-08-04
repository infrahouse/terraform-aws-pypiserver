resource "aws_efs_replication_configuration" "packages" {
  source_file_system_id = aws_efs_file_system.packages.id
  destination {
    region         = data.aws_region.current.name
    file_system_id = aws_efs_file_system.packages-enc.id
  }
}
