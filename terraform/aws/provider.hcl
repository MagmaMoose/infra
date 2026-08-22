# Required by root.hcl, which reads `provider_vars.inputs.provider` and merges
# `provider_vars.locals` into every leaf's inputs. Mirrors terraform/oci/provider.hcl.
#
# Note that root.hcl also carries an unused `aws_version = "5.82.2"` local. It generates a
# required_providers block for OCI only, so nothing pins AWS from there — this stack's
# constraint lives in each module's versions.tf (`~> 6.0`, needed for origin access control
# on Lambda function URLs). If root.hcl ever starts generating an AWS pin, those two have to
# be reconciled or the leaves will fail to init.
locals {
  provider = "aws"
}

inputs = {
  provider = local.provider
}
