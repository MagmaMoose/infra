variable "region" {
  description = <<-EOT
    Region holding the queues, the functions and the table. Supplied by the leaf from
    `region.hcl` (which derives it from the directory name), so the path on disk and the
    region in the ARNs cannot disagree. The provider's own region comes from the leaf's
    generated `aws_provider.tf`; this variable exists because IAM policy documents have to
    build ARNs by hand.
  EOT
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = <<-EOT
    Environment segment of the SSM secret path, e.g. `/nievah/prod/webhook-secret`. Supplied
    by the leaf from `environment.hcl`. Deliberately NOT `terraform.workspace`: Terragrunt
    runs every leaf in the "default" workspace, so using it would collapse prod and any future
    environment onto one path.
  EOT
  type        = string
  default     = "prod"
}

variable "artifact_bucket" {
  description = <<-EOT
    Bucket holding the published Lambda zip. Created by the `artifacts` leaf, which MUST be
    applied first — this leaf takes it as a dependency output rather than hardcoding it so the
    ordering is expressed in the graph rather than in a runbook.
  EOT
  type        = string
}

variable "edge_artifact_version" {
  description = <<-EOT
    Which published edge zip to run, e.g. "1.41.4". Resolves to `edge/<version>.zip` in the
    artifact bucket.

    THIS LINE IS THE DEPLOYMENT. Nievah's release workflow publishes the object and opens the
    bump PR here; merging it is what moves the edge. Objects are immutable and keys are
    version-scoped, so a changed key is the only signal Terraform needs — which is also why
    there is no `source_code_hash` anywhere in this module.

    Nievah only opens that PR when the zip's sha256 actually CHANGED. The zip is seven files;
    most nievah releases touch none of them, and a bump per release would be a stream of PRs
    redeploying byte-identical code until nobody read them.
  EOT
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every resource name. Change it to stand a second stack alongside."
  type        = string
  default     = "nievah"
}

variable "localstack" {
  description = <<-EOT
    Target LocalStack rather than AWS. This is not a cosmetic switch — it removes the two
    resources the free LocalStack image cannot honour, and each removal is a real gap in what
    a local run proves:

      CloudFront            Pro-only. Locally, requests go straight to the Lambda Function
                            URL, so the OAC signing that makes that URL private in production
                            is NOT exercised. Read edge.tf before trusting it.
      EventBridge Scheduler LocalStack accepts a schedule and never fires it, so none is
                            created. aws/localstack/smoke.py invokes the producer with a tick
                            payload directly, which covers everything downstream of the
                            schedule — the part this repo owns.

    Everything else — Lambda, SQS FIFO, DynamoDB conditional writes, S3, IAM — runs for real.
  EOT
  type        = bool
  default     = false
}

variable "domain_name" {
  description = <<-EOT
    Custom hostname for the front door, e.g. "hooks.magmamoose.com". Leave EMPTY to use the
    distribution's own *.cloudfront.net name, which is what the first deploy should do: the
    GitHub App's webhook URL can be repointed in one field at any time, and an empty value
    keeps this stack from needing a certificate, a DNS record, or a second provider in
    us-east-1 before it has ever received a request.
  EOT
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate for `domain_name`. MUST be in us-east-1 — CloudFront reads certificates
    from that region only, whatever region the rest of the stack is in. Required when
    `domain_name` is set; ignored otherwise.
  EOT
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = <<-EOT
    Lambda log retention. Set explicitly because the default is NEVER EXPIRE: a log group
    Lambda creates for itself grows without limit, and CloudWatch Logs' free tier covers 5 GB
    of storage. Two weeks is longer than any incident takes to diagnose.
  EOT
  type        = number
  default     = 14
}

variable "jobs_retention_seconds" {
  description = <<-EOT
    How long the jobs queue holds a delivery the cluster has not taken. SQS's maximum is 14
    days and that is what this is set to — it is a ceiling on how long an outage can last
    before webhooks begin evaporating, and there is no reason to choose a lower one. The
    design it replaces was capped at Cloudflare Queues' 24 hours.
  EOT
  type        = number
  default     = 1209600
}

variable "stale_jobs_alarm_seconds" {
  description = <<-EOT
    Age of the oldest unconsumed job that means the cluster has stopped taking work. THE
    SINGLE MOST USEFUL ALARM IN THIS STACK: it fires from outside the cluster, so it still
    fires when the cluster is the thing that is broken — which is exactly when an in-cluster
    monitor cannot report. 15 minutes is comfortably longer than a rolling deploy.
  EOT
  type        = number
  default     = 900
}

variable "enable_ticks" {
  description = <<-EOT
    Create the EventBridge schedules that replace the two Kubernetes CronJobs.

    DEFAULT FALSE, AND THAT IS A SAFETY INTERLOCK RATHER THAN CAUTION. While
    k8s/base/cronjob.yaml still exists, turning these on means BOTH fire — the CronJob pod
    enqueues a planner run and so does the schedule, at different times, producing different
    ARQ job ids that arq's `unique=True` will not collapse (the same trap already documented
    at the top of cronjob.yaml). Two planner runs an hour apart would file duplicate issues.

    So: suspend or delete the CronJobs FIRST, then set this true. Ordering the other way
    around is the failure.
  EOT
  type        = bool
  default     = false
}

variable "ops_email" {
  description = "Address subscribed to the ops topic. Empty to skip. AWS emails a confirmation link."
  type        = string
  default     = ""
}

variable "slack_workspace_id" {
  description = <<-EOT
    AWS Chatbot workspace id, for alarms in Slack. Empty to skip. The workspace must be
    authorized once by hand in the AWS Chatbot console (an OAuth handshake Terraform cannot
    perform); after that this wires the channel. Chatbot itself is free.
  EOT
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "Slack channel id for alarms, e.g. C0123456789. Required with slack_workspace_id."
  type        = string
  default     = ""
}
