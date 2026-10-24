terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 7.0"
    }
  }

  # Recomendado: estado remoto cifrado, p. ej.
  # backend "s3" { bucket = "mi-tfstate" key = "lakehouse/aws.tfstate" region = "us-east-1" }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}
