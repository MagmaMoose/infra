variable "zone_id" {
  description = "Cloudflare zone ID to manage records in"
  type        = string
}

variable "records" {
  description = "List of DNS records to create. Multiple entries with the same name + type create a multi-value (round-robin) record. Set `value` for an ordinary record, or `data` instead for SVCB/HTTPS, whose RDATA is structured (priority, target and the SvcParams string)."
  type = list(object({
    name    = string
    type    = string
    value   = optional(string)
    ttl     = optional(number, 1)
    proxied = optional(bool, false)
    data = optional(object({
      priority = number
      target   = string
      value    = string
    }))
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.records : (r.value == null) != (r.data == null)])
    error_message = "Each record sets exactly one of `value` or `data`. The provider rejects a record that carries both, and the record key is built from whichever one is set."
  }

  # Caught here because the API only refuses it at apply time, after a clean plan.
  validation {
    condition     = alltrue([for r in var.records : r.data == null || (contains(["SVCB", "HTTPS"], r.type) && !r.proxied)])
    error_message = "`data` models SVCB/HTTPS RDATA (priority, target, value) and nothing else, and those records must stay DNS-only: Cloudflare proxies A, AAAA and CNAME only."
  }
}

variable "imports" {
  description = "Pre-existing Cloudflare records to bring under terraform management. Each entry needs the same `name#type#value` key used in `records` (for a `data` record the last part is its RDATA, `<priority> <target> <value>`) plus the record's Cloudflare ID. Used for initial dashboard→terraform migration; can be empty after the first apply lands."
  type = list(object({
    key       = string
    record_id = string
  }))
  default = []
}

variable "enable_dnssec" {
  description = "Sign the zone with DNSSEC. Off by default. Signing alone validates nothing: the DS record in the dnssec_ds_record output has to be published at the registrar first."
  type        = bool
  default     = false
}
