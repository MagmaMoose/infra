include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/oci/modules/mikrotik"
}

# No `generate "provider"` override: terragrunt v0.63.6 errors on duplicate
# generate block names rather than letting children override parents. We rely
# on root.hcl's generated provider.tf (google + oci) and just don't use the
# oci provider in this module — declaring it in required_providers is enough
# to satisfy OpenTofu; the unused provider block stays inert.

# routeros provider declaration. Lives in an `_override.tf` file so OpenTofu
# merges it into the parent-generated provider.tf's required_providers map
# (one-required_providers-per-module rule). Sidesteps the same-name-generate
# conflict with the root.hcl `generate "provider"` block.
generate "routeros_required" {
  path      = "routeros_override.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    terraform {
      required_providers {
        routeros = {
          source  = "terraform-routeros/routeros"
          version = "1.99.1"
        }
      }
    }
  EOF
}

# Secrets live in OCI Vault (vault-prod) and are fetched at parse time via
# the `oci` CLI, which uses ~/.oci/config — no extra env vars needed.
#
# Previously sourced from 1Password (`op read`), but everything else in this
# repo's secret access pattern is OCI-Vault-first, and the op flow added a
# desktop-integration dependency to every terragrunt run on the mikrotik
# module. The `mikrotik-credentials` secret stores admin creds as JSON
# `{baseurl,username,password}`; we extract the password with jq.
locals {
  routeros_password_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aaaizjuctq6do5iou2xo5yibpuiirdwwdjurwllubxlima" # vault-prod / mikrotik-credentials (JSON)
  # TODO(firefly-oci-split): swap this OCID to the firefly-oci tunnel secret
  # once the bootstrap from terraform/cloudflare/zero-trust/prod is done.
  # Keeping the original firefly OCID here for now so this terragrunt project
  # stays parseable — run_cmd below interpolates the OCID at parse time, so
  # a placeholder would break terragrunt plan / Atlantis autoplan everywhere
  # this file is touched. As long as the cloudflared container on the OCI
  # MikroTiks is held in stop+no-restart state (RouterOS hotfix applied
  # 2026-05-24 — verify with `/container print` before reapplying), this
  # OCID is harmless: an apply just re-stores the firefly token in state but
  # doesn't actually start the container.
  # Bootstrap order to complete the split:
  #   1. apply cloudflare/zero-trust/prod  → firefly_oci tunnel created
  #   2. cd terraform/cloudflare/zero-trust/prod && terragrunt output -raw firefly_oci_tunnel_token
  #   3. printf %s "<token>" | base64 | oci vault secret create-base64 \
  #        --secret-name cloudflared-tunnel-token-firefly-oci \
  #        --vault-id <vault-prod ocid> --compartment-id <tenancy ocid> \
  #        --secret-content-content file:///dev/stdin
  #   4. Update this OCID in a follow-up commit, then re-apply this module —
  #      the container is recreated with the firefly-oci token and starts
  #      cleanly without re-joining the firefly tunnel.
  cloudflared_tunnel_token_secret_ocid = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aa2awevyczjklffua7eugrlxbsz4xziug5x5jgpewsbwfa" # vault-prod / cloudflared-tunnel-token-firefly  (TODO: swap to cloudflared-tunnel-token-firefly-oci)
  recon_blockers_secret_ocid           = "ocid1.vaultsecret.oc1.eu-amsterdam-1.amaaaaaa4ebs56aa7mytuezgibzn4g36jxupsgy57zl4372uq47atgfra2ka" # vault-prod / infra-recon-blockers

  # Direct `oci` calls + base64decode/jsondecode in HCL (no `bash -c`, no jq) so
  # these parse on Windows/PowerShell, which has no bash. Pattern:
  # cloudflare/zero-trust/prod. The mikrotik-credentials secret is JSON
  # {baseurl,username,password}; we pull .password in HCL.
  routeros_password = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.routeros_password_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))["password"]

  cloudflared_tunnel_token = base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.cloudflared_tunnel_token_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  )))

  # The trusted-address list labels reveal the operator's employer and the
  # two family residences by name + IP/hostname — moved into OCI Vault so
  # only the operator's authenticated principals (or atlantis) see them.
  # JSON sub-key: `mikrotik_trusted_addresses` → map(label -> ip-or-host).
  recon_blockers = jsondecode(base64decode(trimspace(run_cmd(
    "--terragrunt-quiet",
    "oci", "secrets", "secret-bundle", "get",
    "--secret-id", local.recon_blockers_secret_ocid,
    "--region", "eu-amsterdam-1",
    "--query", "data.\"secret-bundle-content\".content",
    "--raw-output"
  ))))
}

inputs = {
  # Using the binary API on port 8728 because:
  #   - www-ssl (HTTPS REST) currently won't complete TLS handshakes despite
  #     a signed local-cert bound to the service (root cause unresolved)
  #   - www (plain HTTP REST) returns 403 — RouterOS policy locks REST to
  #     HTTPS regardless of user permissions
  # The binary API uses a challenge-response auth so the password isn't on
  # the wire in cleartext, even though the session itself is unencrypted.
  # TODO: migrate to apis://...:8729 (TLS-wrapped binary API) once cert is
  # working, or back to https:// REST.
  routers = {
    r1 = { hosturl = "api://134.98.139.9:8728" }
    r2 = { hosturl = "api://193.123.39.172:8728" }
  }

  routeros_username        = "admin"
  routeros_password        = local.routeros_password
  cloudflared_tunnel_token = local.cloudflared_tunnel_token

  # The vault list carries the operator's employer and both family residences by
  # name, which is why it is not in this public repo. The two entries merged in
  # here are neither: they are OCI reserved public IPs in the operator's own
  # second tenancy, and firefly's own pair is already inlined a few lines up as
  # `routers`.
  #
  # They have to be here because these two CHRs now dial WireGuard at ff-chr1 and
  # ff-chr2 (terraform/mikrotik/wireguard-mesh/prod). The input chain this module
  # builds is `accept established/related`, `accept TRUSTED`, then a blanket drop
  # — so a handshake INITIATED by ff-chr3 lands on the drop unless its source is
  # trusted. It would half-work without this: whichever side dials first gets a
  # conntrack entry and the reply rides `established`, so the tunnel comes up
  # and then fails to re-establish after a restart on the wrong side. Worth
  # naming, because that is the kind of fault that looks like flapping hardware.
  #
  # The third entry is the mesh's own transit range, and it is what makes the
  # routes over that mesh usable at all. Each route carries check-gateway=ping,
  # so ff-chr1 must answer an ICMP echo sent to its own 192.168.255.x transit
  # address by the far router. This module's input chain is
  # established/related -> TRUSTED -> drop, and the transit /26 matched none of
  # them: the tunnels handshaked, traffic could have flowed, and every route
  # across them sat `inactive` because the health check was being dropped by the
  # router the check was aimed at. (The RFC1918 list does not help — this module
  # only uses it in the forward chain.)
  trusted_addresses = merge(local.recon_blockers.mikrotik_trusted_addresses, {
    "Cloudworkers OCI ff-chr3, Amsterdam, NL" = "158.178.154.125"
    "Cloudworkers OCI ff-chr4, Amsterdam, NL" = "84.235.162.6"
    "WireGuard mesh transit"                  = "192.168.255.0/26"
  })

  # Masquerade outbound traffic from app + data subnets so they can use this
  # MikroTik as their internet gateway (paired with the 0.0.0.0/0 route in the
  # network module). edge subnet is excluded — it has its own IGW route.
  vcn_masquerade_sources = [
    "192.168.223.64/26",  # app subnet
    "192.168.223.128/26", # data subnet
  ]
}
