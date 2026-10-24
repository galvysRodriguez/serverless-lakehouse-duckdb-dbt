variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "name" {
  description = "Prefijo de nombres y valor de la etiqueta `project`."
  type        = string
  default     = "lakehouse"
}

variable "bucket_name" {
  description = "Nombre global único del bucket del lago."
  type        = string
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "cpu" {
  type    = string
  default = "2"
}

variable "memory" {
  description = "Memoria del contenedor en Gi (p. ej. 4Gi); DuckDB recibe ~75 % (DUCKDB_MEMORY_LIMIT)."
  type        = string
  default     = "4Gi"
  validation {
    condition     = can(regex("^[0-9.]+Gi$", var.memory))
    error_message = "Expresa la memoria en Gi, p. ej. 4Gi."
  }
}

variable "duckdb_memory_limit" {
  type    = string
  default = "3GB"
}

variable "billing_account_id" {
  description = "Cuenta de facturación para el presupuesto. Vacío = no se crea."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 20
}

variable "price_per_vcpu_second" {
  description = "Precios de lista de Cloud Run (facturación por petición) para estimar el costo de cada ejecución. Verifícalos para tu región."
  type        = number
  default     = 0.000024
}

variable "price_per_gib_second" {
  type    = number
  default = 0.0000025
}

variable "price_per_request" {
  type    = number
  default = 0.0000004
}
