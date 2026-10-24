locals {
  labels = {
    project    = var.name
    managed_by = "terraform"
  }
  marker_prefix = "raw/ecommerce/_markers/"
  cost_per_second = (
    tonumber(var.cpu) * var.price_per_vcpu_second
    + tonumber(trimsuffix(var.memory, "Gi")) * var.price_per_gib_second
  )
  image_repo = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/lakehouse"
}

data "google_project" "current" {}

resource "google_project_service" "apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# --- Almacenamiento -----------------------------------------------------------

resource "google_storage_bucket" "lake" {
  name                        = var.bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels

  # Raw solo se relee en backfills. A diferencia de S3, GCS no cobra un tamaño
  # mínimo por objeto en Nearline/Coldline (sí una duración mínima: 30/90 días).
  lifecycle_rule {
    condition {
      age            = 30
      matches_prefix = ["raw/"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age            = 90
      matches_prefix = ["raw/"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository" "images" {
  repository_id = var.name
  location      = var.region
  format        = "DOCKER"
  labels        = local.labels

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 días
    }
  }

  depends_on = [google_project_service.apis]
}

# --- Identidad del pipeline y credenciales para DuckDB ------------------------

resource "google_service_account" "runner" {
  account_id   = "${var.name}-runner"
  display_name = "Lakehouse dbt + DuckDB (Cloud Run)"
}

resource "google_storage_bucket_iam_member" "runner" {
  bucket = google_storage_bucket.lake.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.runner.email}"
}

# DuckDB habla con GCS por la API compatible con S3, que requiere claves HMAC.
resource "google_storage_hmac_key" "runner" {
  service_account_email = google_service_account.runner.email
}

resource "google_secret_manager_secret" "hmac" {
  for_each  = toset(["key-id", "secret"])
  secret_id = "${var.name}-hmac-${each.key}"
  labels    = local.labels
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "hmac" {
  for_each = {
    "key-id" = google_storage_hmac_key.runner.access_id
    "secret" = google_storage_hmac_key.runner.secret
  }
  secret      = google_secret_manager_secret.hmac[each.key].id
  secret_data = each.value
}

resource "google_secret_manager_secret_iam_member" "runner" {
  for_each  = google_secret_manager_secret.hmac
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

# --- Cómputo serverless (scale-to-zero) ---------------------------------------

resource "google_cloud_run_v2_service" "pipeline" {
  name                = var.name
  location            = var.region
  deletion_protection = false
  labels              = local.labels

  template {
    service_account = google_service_account.runner.email
    timeout         = "3600s"
    # dbt no es thread-safe: una petición por instancia y una sola instancia, así
    # dos días nunca escriben Gold al mismo tiempo.
    max_instance_request_concurrency = 1

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image = "${local.image_repo}:${var.image_tag}"

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        # Solo se factura CPU mientras hay una petición en curso.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      env {
        name  = "LAKE_ROOT"
        value = "gs://${google_storage_bucket.lake.name}"
      }
      env {
        name  = "DUCKDB_MEMORY_LIMIT"
        value = var.duckdb_memory_limit
      }
      # Estimación de costo por ejecución (ver src/lakehouse/metrics.py).
      env {
        name  = "LAKEHOUSE_COST_PER_SECOND"
        value = format("%.10f", local.cost_per_second)
      }
      env {
        name  = "LAKEHOUSE_COST_PER_RUN"
        value = format("%.10f", var.price_per_request)
      }
      env {
        name = "GCS_HMAC_KEY_ID"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.hmac["key-id"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "GCS_HMAC_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.hmac["secret"].secret_id
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_iam_member.runner,
    google_secret_manager_secret_version.hmac,
  ]
}

# --- Disparador: marcador _SUCCESS -> Pub/Sub -> Cloud Run --------------------

data "google_storage_project_service_account" "gcs" {}

resource "google_pubsub_topic" "markers" {
  name                       = "${var.name}-markers"
  labels                     = local.labels
  message_retention_duration = "86400s"
  depends_on                 = [google_project_service.apis]
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic  = google_pubsub_topic.markers.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# Filtra por prefijo en origen: las escrituras de bronze/silver/gold no generan
# mensajes ni despiertan el servicio.
resource "google_storage_notification" "markers" {
  bucket             = google_storage_bucket.lake.name
  topic              = google_pubsub_topic.markers.id
  payload_format     = "JSON_API_V1"
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = local.marker_prefix
  depends_on         = [google_pubsub_topic_iam_member.gcs_publisher]
}

resource "google_service_account" "pusher" {
  account_id   = "${var.name}-pusher"
  display_name = "Pub/Sub push hacia Cloud Run"
}

resource "google_cloud_run_v2_service_iam_member" "pusher" {
  name     = google_cloud_run_v2_service.pipeline.name
  location = google_cloud_run_v2_service.pipeline.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pusher.email}"
}

# Pub/Sub firma el token OIDC en nombre de la cuenta pusher.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.pusher.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription" "push" {
  name   = "${var.name}-markers-push"
  topic  = google_pubsub_topic.markers.id
  labels = local.labels

  # Máximo permitido por Pub/Sub. Si un build tarda más, el mensaje se reentrega;
  # el pipeline es idempotente por día, pero para cargas largas conviene Cloud Run Jobs.
  ack_deadline_seconds = 600

  push_config {
    push_endpoint = google_cloud_run_v2_service.pipeline.uri
    oidc_token {
      service_account_email = google_service_account.pusher.email
      audience              = google_cloud_run_v2_service.pipeline.uri
    }
  }

  retry_policy {
    minimum_backoff = "60s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.max_delivery_attempts
  }

  expiration_policy {
    ttl = "" # nunca expira por inactividad
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.pusher,
    google_service_account_iam_member.pubsub_token_creator,
    google_pubsub_topic_iam_member.dead_letter_publisher,
  ]
}

# --- Alertas ------------------------------------------------------------------

locals {
  pubsub_agent = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  channels     = google_monitoring_notification_channel.email[*].id
}

# Mensajes que agotaron los reintentos. Se guardan 7 días en una suscripción pull
# para inspeccionarlos o reinyectarlos.
resource "google_pubsub_topic" "dead_letter" {
  name       = "${var.name}-markers-dlq"
  labels     = local.labels
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_subscription" "dead_letter" {
  name                       = "${var.name}-markers-dlq"
  topic                      = google_pubsub_topic.dead_letter.id
  labels                     = local.labels
  message_retention_duration = "604800s"
  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  topic  = google_pubsub_topic.dead_letter.id
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

# Pub/Sub necesita poder confirmar el mensaje original al moverlo a la dead-letter.
resource "google_pubsub_subscription_iam_member" "dead_letter_ack" {
  subscription = google_pubsub_subscription.push.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email == "" ? 0 : 1
  display_name = "${var.name} alertas"
  type         = "email"
  labels       = { email_address = var.alert_email }
  depends_on   = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "dead_letter" {
  display_name          = "${var.name}: día sin procesar (dead-letter)"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = "Mensajes en la dead-letter"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${google_pubsub_subscription.dead_letter.name}\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  documentation {
    content = "Un marcador _SUCCESS agotó ${var.max_delivery_attempts} intentos. Revisa los logs de Cloud Run y reinyecta el mensaje desde la suscripción ${google_pubsub_subscription.dead_letter.name}."
  }
}

resource "google_monitoring_alert_policy" "errors" {
  display_name          = "${var.name}: errores 5xx del pipeline"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = "Respuestas 5xx de Cloud Run"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${google_cloud_run_v2_service.pipeline.name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.labels.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }
}

# --- FinOps: presupuesto ------------------------------------------------------

resource "google_billing_budget" "monthly" {
  count           = var.billing_account_id == "" ? 0 : 1
  billing_account = var.billing_account_id
  display_name    = "${var.name}-monthly"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
    labels   = { project = var.name }
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "FORECASTED_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
  }
}
