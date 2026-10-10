output "record_ids" {
  description = "Map of record key (name#type#value) to Cloudflare record ID"
  value       = { for k, r in cloudflare_record.this : k => r.id }
}

output "record_hostnames" {
  description = "Map of record key to hostname (name)"
  value       = { for k, r in cloudflare_record.this : k => r.hostname }
}

# `one()` rather than `[0]`: the resource is count-gated, so on a zone without
# DNSSEC this is null instead of an index error.
output "dnssec_ds_record" {
  description = "What the registrar needs to anchor the zone's DNSSEC in its parent, or null when enable_dnssec is false. `ds` is the full DS record; key_tag, algorithm, digest_type and digest are the same record split into the fields a registrar form asks for; flags and public_key are the DNSKEY, for a registrar that wants that instead. Public DNS data, not a secret."
  value = one([
    for z in cloudflare_zone_dnssec.this : {
      ds          = z.ds
      key_tag     = z.key_tag
      algorithm   = z.algorithm
      digest_type = z.digest_type
      digest      = z.digest
      flags       = z.flags
      public_key  = z.public_key
    }
  ])
}
