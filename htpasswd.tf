resource "random_password" "password" {
  length  = 21
  special = false
}

resource "random_pet" "username" {}

module "pypiserver_secret" {
  source             = "registry.infrahouse.com/infrahouse/secret/aws"
  version            = "0.5.0"
  secret_name_prefix = "PYPISERVER_SECRET"
  secret_description = "Username and password for the basic http authentication on the PyPI server."
  secret_value = jsonencode(
    {
      username : random_pet.username.id
      password : random_password.password.result
      bcrypt_hash : random_password.password.bcrypt_hash
    }
  )
  readers = var.secret_readers
}
