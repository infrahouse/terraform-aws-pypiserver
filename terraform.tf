terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.11, < 5.37.0"
      configuration_aliases = [
        aws.dns # AWS provider for DNS
      ]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "~> 1.0"
    }
  }
}
