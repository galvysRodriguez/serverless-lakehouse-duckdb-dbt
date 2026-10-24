output "bucket" {
  value = google_storage_bucket.lake.name
}

output "lake_root" {
  value = "gs://${google_storage_bucket.lake.name}"
}

output "image_repository" {
  value = local.image_repo
}

output "service_url" {
  value = google_cloud_run_v2_service.pipeline.uri
}

output "runner_service_account" {
  value = google_service_account.runner.email
}

output "dead_letter_subscription" {
  value = google_pubsub_subscription.dead_letter.name
}
