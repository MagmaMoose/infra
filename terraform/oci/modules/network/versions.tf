# required_providers is declared in terraform/root.hcl's generate "provider"
# block (shared with other modules under terraform/oci/). Adding another
# `terraform { required_providers {} }` here would collide with the generated
# one — OpenTofu allows only one per module. Keep this file for the
# required_version pin only.
terraform {
  # `one()` in main.tf's next-hop locals needs 0.15+; the repo standard is the
  # same 1.9.0 floor every other module under terraform/oci/ pins, so the two
  # tenancies' leaves cannot diverge on the toolchain.
  required_version = ">= 1.9.0"
}
