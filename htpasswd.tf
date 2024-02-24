resource "random_password" "password" {
  length  = 21
  special = false
}

resource "random_pet" "username" {
}

resource "aws_secretsmanager_secret" "pypiserver_secret" {
  name_prefix             = "PYPISERVER_SECRET"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "pypiserver_secret" {
  secret_id = aws_secretsmanager_secret.pypiserver_secret.id
  secret_string = jsonencode(
    {
      username : random_pet.username.id
      password : random_password.password.result
      bcrypt_hash : random_password.password.bcrypt_hash
    }
  )
}
