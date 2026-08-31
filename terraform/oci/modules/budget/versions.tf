# required_providers is declared in terraform/root.hcl's generate "provider"
# block (shared with other modules under terraform/oci/). Adding another
# `terraform { required_providers {} }` here would collide with the generated
# one — OpenTofu allows only one per module. Keep this file for the
# required_version pin only.
terraform {
  required_version = ">= 1.9.0" # provider for_each was added in OpenTofu 1.9
}
