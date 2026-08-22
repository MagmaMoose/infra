# NO `provider` block and NO `backend` block, deliberately — see the matching note in
# modules/nievah-frontdoor/versions.tf. Terragrunt's root.hcl generates `provider.tf` and
# `backend.tf` with `if_exists = "overwrite"`, and the leaf generates `aws_provider.tf` on
# top of that, so anything declared here would be silently replaced on the next run.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Same major as the front door, for one concrete reason rather than symmetry:
      # `aws_chatbot_slack_channel_configuration` and `aws_scheduler_schedule` are both used
      # here, and both moved behaviour across the 5 -> 6 boundary.
      version = "~> 6.0"

      # The billing plane is single-region. S3 bucket, bucket policy and the Data Export all
      # live in us-east-1 while the Lambda, SNS topic and Chatbot config stay in the leaf's
      # region — Chatbot has no us-east-1 endpoint at all, so this genuinely cannot collapse
      # to one provider.
      configuration_aliases = [aws.us_east_1]
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
