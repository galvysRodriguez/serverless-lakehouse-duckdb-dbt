terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # Recomendado: estado remoto cifrado. El estado guarda el secreto HMAC.
  # backend "gcs" { bucket = "mi-tfstate" prefix = "lakehouse/gcp" }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
