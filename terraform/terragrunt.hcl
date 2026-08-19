remote_state {
  backend = "gcs"
  config = {
    bucket      = "terraform-state-firefly"
    prefix      = "terraform/gcp_project"
    credentials = "${get_env("GOOGLE_APPLICATION_CREDENTIALS", "${get_repo_root()}/terraform/.service-account.json")}"
    project     = "sargeant-terraform-states"
  }
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  backend "gcs" {}
}
EOF
}