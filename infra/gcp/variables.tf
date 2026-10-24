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
  description = "Memoria del contenedor; DuckDB recibe ~75 % (DUCKDB_MEMORY_LIMIT)."
  type        = string
  default     = "4Gi"
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
