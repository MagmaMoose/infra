terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# Provider configuration is the caller's responsibility (see
# https://developer.hashicorp.com/terraform/language/modules/develop/providers).
# The calling terragrunt.hcl generates a provider.tf with the api_token.

# Key records by name#type#value so the same name+type can appear twice with
# different values (round-robin), which is how oci.sargeant.co resolves to
# both r1 and r2.
#
# A structured record (SVCB/HTTPS, set through `data`) has no single value, so
# its key ends in the record's RDATA in presentation form instead, e.g.
#   _mcp._agents.magmamoose.com#SVCB#1 mcp.magmamoose.com. alpn="mcp,h2,h3" port="443"
# Every record that sets `value` keeps exactly the key it always had, so no
# existing state address moves.
locals {
  records = {
    for r in var.records :
    "${r.name}#${r.type}#${r.data == null ? r.value : format("%d %s %s", r.data.priority, r.data.target, r.data.value)}" => r
  }
}

resource "cloudflare_record" "this" {
  for_each = local.records

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  # Null for a structured record. The provider takes exactly one of content and
  # data (ExactlyOneOf), and the API derives content from data by itself.
  content = each.value.value
  ttl     = each.value.ttl
  proxied = each.value.proxied
  comment = "Managed by Terraform"

  # SVCB/HTTPS only. Every other record renders zero blocks, which is what it
  # already has in state, so existing records plan as no-ops.
  dynamic "data" {
    for_each = each.value.data == null ? [] : [each.value.data]
    content {
      priority = data.value.priority
      target   = data.value.target
      value    = data.value.value
    }
  }
}

# Import blocks for records that already exist in the dashboard. Empty
# `imports` list = no imports (the steady state once initial migration is
# done).
import {
  for_each = { for i in var.imports : i.key => i }
  to       = cloudflare_record.this[each.key]
  id       = "${var.zone_id}/${each.value.record_id}"
}

# DNSSEC signing for the zone. Opt-in, and off by default, so a zone that does
# not ask for it (sargeant.co today) plans exactly as before.
#
# This only SIGNS the zone. Nothing validates until the DS record is published
# in the parent zone, which is done at the registrar and not in Cloudflare: the
# values are in the dnssec_ds_record output. Until Cloudflare sees that DS it
# reports the status as "pending". The v4 resource treats status as read-only,
# so a pending zone is not a diff on every plan (v5 declares status as an
# input, and plans "pending" -> "active" until the DS lands).
#
# DESTROYING THIS TURNS DNSSEC OFF. Once a DS is live at the registrar, remove it
# there first and wait out its TTL. Disabling signing while the parent still
# publishes a DS makes every validating resolver SERVFAIL the whole zone, and a
# plain revert of the change that added this does exactly that.
resource "cloudflare_zone_dnssec" "this" {
  count = var.enable_dnssec ? 1 : 0

  zone_id = var.zone_id
}
