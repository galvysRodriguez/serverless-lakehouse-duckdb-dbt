variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  description = "Prefijo de nombres y valor de la etiqueta `project` (usada para asignar costos)."
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

variable "lambda_architecture" {
  description = "arm64 (Graviton) cuesta ~20 % menos por GB-s que x86_64. Debe coincidir con la plataforma de la imagen."
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "x86_64"], var.lambda_architecture)
    error_message = "Usa arm64 o x86_64."
  }
}

variable "lambda_memory_mb" {
  description = "Memoria de la Lambda; la CPU escala con ella. DuckDB recibe el 75 %."
  type        = number
  default     = 3008
}

variable "reserved_concurrency" {
  description = "1 = una ejecución a la vez (evita escrituras concurrentes en Gold). -1 = sin reservar (cuentas nuevas con límite de 10 no permiten reservar)."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "monthly_budget_usd" {
  type    = number
  default = 20
}

variable "budget_email" {
  description = "Email para alertas de presupuesto. Vacío = no se crea el presupuesto."
  type        = string
  default     = ""
}

variable "cost_center" {
  type    = string
  default = "data"
}

variable "lambda_price_per_gb_second" {
  description = "Precio de lista de Lambda por GB-segundo, para estimar el costo de cada ejecución en ops/pipeline_runs. Verifícalo para tu región."
  type        = map(number)
  default = {
    arm64  = 0.0000133334
    x86_64 = 0.0000166667
  }
}

variable "lambda_price_per_request" {
  type    = number
  default = 0.0000002
}
