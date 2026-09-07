# Cloudflare Access applications + their policies. Imported as-is; every
# field that the CF dashboard set is mirrored here so the first apply is a
# pure state reconciliation.

# --- self_hosted: Radarr ----------------------------------------------------
# Was a bookmark before — that meant the launcher icon existed but the app
# itself wasn't gated by Access at all (bookmarks don't authenticate).
# Now properly self_hosted, behind the same Friends + Caleb policies as
# Overseerr. Reachable via the firefly cloudflared tunnel (ingress in
# tunnels.tf) + the radarr CNAME in cloudflare/dns/prod (created in same PR).
#
# NOTE: this is a ForceNew type change (bookmark → self_hosted) — terraform
# destroys the old bookmark app and creates the new self_hosted one. Brief
# launcher-icon flicker during apply; the URL itself stays
# `https://radarr.sargeant.co` (was the bookmark target, now the
# self_hosted domain).
resource "cloudflare_zero_trust_access_application" "radarr" {
  account_id                = var.account_id
  name                      = "Radarr"
  type                      = "self_hosted"
  domain                    = "radarr.sargeant.co"
  logo_url                  = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/radarr-4k.png"
  tags                      = ["Sargeant"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "radarr_friends" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.radarr.id
  name             = "Friends"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.friends.id]
  }
}

resource "cloudflare_zero_trust_access_policy" "radarr_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.radarr.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 2
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }

  # Mirror overseerr_caleb's posture requirements: Caleb's Radarr session
  # only valid from a macOS device with FileVault on + current OS version.
  # Firewall posture intentionally omitted (many dev Macs have system
  # firewall off; revisit when that changes).
  require {
    device_posture = [
      cloudflare_zero_trust_device_posture_rule.mac_disk_encryption.id,
      cloudflare_zero_trust_device_posture_rule.mac_os_version.id,
    ]
  }
}

# --- bookmark: AWS Access Portal (magmamoose) -------------------------------
resource "cloudflare_zero_trust_access_application" "aws_magmamoose" {
  account_id                = var.account_id
  name                      = "AWS Access Portal"
  type                      = "bookmark"
  domain                    = "https://magmamoose.awsapps.com/start"
  logo_url                  = "https://www.pngplay.com/wp-content/uploads/3/Amazon-Web-Services-AWS-Logo-Transparent-PNG.png"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
}

# --- bookmark: AWS Access Portal (platform-1) -------------------------------
resource "cloudflare_zero_trust_access_application" "aws_platform_1" {
  account_id                = var.account_id
  name                      = "AWS Access Portal"
  type                      = "bookmark"
  domain                    = "https://platform-1.awsapps.com/start"
  logo_url                  = "https://www.pngplay.com/wp-content/uploads/3/Amazon-Web-Services-AWS-Logo-Transparent-PNG.png"
  tags                      = ["Platform1"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
}

# --- self_hosted: Overseerr -------------------------------------------------
resource "cloudflare_zero_trust_access_application" "overseerr" {
  account_id                = var.account_id
  name                      = "Overseerr"
  type                      = "self_hosted"
  domain                    = "overseerr.sargeant.co"
  logo_url                  = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/overseerr.svg"
  tags                      = ["Sargeant"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "overseerr_friends" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.overseerr.id
  name             = "Friends"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.friends.id]
  }
}

resource "cloudflare_zero_trust_access_policy" "overseerr_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.overseerr.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 2
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }

  # Caleb's session is only valid from a macOS device with FileVault on
  # and a current OS version. Firewall posture rule is intentionally NOT
  # included (many dev Macs have the system firewall off; flip on
  # cluster-wide and we can add it). Friends policy stays posture-less —
  # mixed-device family/friends shouldn't be locked out by Apple posture.
  require {
    device_posture = [
      cloudflare_zero_trust_device_posture_rule.mac_disk_encryption.id,
      cloudflare_zero_trust_device_posture_rule.mac_os_version.id,
    ]
  }
}

# --- warp: Warp Login App ---------------------------------------------------
# WARP login is unusual — CF returns logo_url=null, tags=[], allowed_idps=[],
# app_launcher_visible=null. We mirror that so the import doesn't try to set
# anything new. auto_redirect_to_identity=false matches.
resource "cloudflare_zero_trust_access_application" "warp_login" {
  account_id                = var.account_id
  name                      = "Warp Login App"
  type                      = "warp"
  domain                    = "magmamoose.cloudflareaccess.com/warp"
  tags                      = []
  allowed_idps              = []
  app_launcher_visible      = false # CF returns null for warp apps; pin false to match
  auto_redirect_to_identity = false
  session_duration          = "24h"
}

resource "cloudflare_zero_trust_access_policy" "warp_email_domain" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.warp_login.id
  name             = "Email domain policy"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  # Was inline `email = ["caleb.sargeant@icloud.com"]` — now references
  # the caleb_personal group whose membership lives in OCI Vault, so the
  # personal email address isn't published in the public repo.
  include {
    group = [cloudflare_zero_trust_access_group.caleb_personal.id]
  }
}

resource "cloudflare_zero_trust_access_policy" "warp_allow_emails" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.warp_login.id
  name             = "Allow emails: 1/19/2026"
  decision         = "allow"
  precedence       = 2
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.household.id]
  }
}

# --- app_launcher -----------------------------------------------------------
resource "cloudflare_zero_trust_access_application" "app_launcher" {
  account_id                = var.account_id
  name                      = "App Launcher"
  type                      = "app_launcher"
  domain                    = "magmamoose.cloudflareaccess.com"
  app_launcher_visible      = false # the launcher itself; CF returns null here, pin false to match
  auto_redirect_to_identity = true
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
  ]
}

# NOTE: the App Launcher's visibility policy is intentionally NOT managed here.
# Cloudflare already has a dashboard-created "Caleb" policy at precedence 1 on this
# app launcher. A terraform-managed "Magma Moose" (magma_moose_domain group) policy
# used to be declared here at the SAME precedence 1, so it could never apply — every
# `plan` wanted to create a second, colliding precedence-1 policy (the app launcher
# stayed drift-y with a perpetual "1 to add"). Removed to make the plan converge
# with zero access change. If we later want the launcher exposed to the whole
# @magmamoose.com domain group, adopt the existing policy first via an
# `import { to = ...; id = "account/<acct>/<app_id>/<policy_id>" }` block (see
# imports.tf) — and confirm Caleb's CF login identity is in magma_moose_domain
# before broadening, or it's a lockout.

# --- Dün Mir — gated by the app itself, NOT Cloudflare Access ----------------
# The operator console (github.com/MagmaMoose/dunmir) authenticates CUSTOMERS
# itself: first-party password + mandatory TOTP against opaque server-side
# sessions, scoping each operator to their own tenant. The Access application
# that used to gate it was removed and stays removed — Access would double-gate
# and block self-serve sign-up outright, since only members of the Caleb access
# group could reach the sign-up page at all.
#
# (This block described Stytch B2B magic links until the app moved to
# first-party auth. Stytch is gone from the product; only the conclusion here is
# unchanged, and it is the conclusion that matters: no Access app on this
# hostname, deliberately.)
#
# Nothing to apply — there is no resource here. It is a signpost for the next
# person who wonders why a public product surface has no Access policy.

# --- self_hosted: Dün Mir docs (MkDocs on Cloudflare Pages) -----------------
# Gated on purpose: this docs site carries internal operational detail that
# must not be world-readable (Cloudflare Pages projects are public by default).
# tremvok's `require-access: True` makes the docs workflow refuse to publish
# until an Access app covers the hostname. This is that app: the whole
# @magmamoose.com team can reach the docs (magma_moose_domain), nobody else can.
# If the docs are ever meant to be public product docs, move the internal pages
# out of published docs/ first, then relax the gate -- not to widen this policy.
resource "cloudflare_zero_trust_access_application" "dunmir_docs" {
  account_id                = var.account_id
  name                      = "Dün Mir docs"
  type                      = "self_hosted"
  domain                    = "dunmir-docs.pages.dev"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "dunmir_docs_team" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.dunmir_docs.id
  name             = "Magma Moose team"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.magma_moose_domain.id]
  }
}

# --- self_hosted: Zoey ------------------------------------------------------
# Zoey — the project-intelligence dashboard (firefly cluster, behind the
# firefly cloudflared tunnel — ingress in tunnels.tf). The app has no in-app
# auth, so Access is the only thing gating the UI: Caleb-only. No
# device-posture `require` — same reasoning as Zoey (the
# posture rules need a WARP-enrolled device Caleb doesn't have), and Zoey is
# a companion dashboard Caleb will want from his phone too.
#
# Zoey's Slack webhooks (everything under /api/v1/slack/) are carved out by
# the separate bypass app below — Slack's POSTs can't carry an Access cookie.
resource "cloudflare_zero_trust_access_application" "zoey" {
  account_id                = var.account_id
  name                      = "Zoey"
  type                      = "self_hosted"
  domain                    = "zoey.sargeant.co"
  tags                      = ["Sargeant"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "zoey_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.zoey.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}

# Bypass app for Zoey's Slack webhooks. Cloudflare Access matches the
# most-specific path first, so POSTs under /api/v1/slack/ — the interaction
# webhook and the app_mention events listener — hit this bypass app instead
# of the Caleb gate above. Slack can't authenticate through Access; every
# /api/v1/slack/* endpoint verifies the Slack v0 HMAC signature itself
# (SLACK_SIGNING_SECRET), so unauthenticated reachability is safe here.
resource "cloudflare_zero_trust_access_application" "zoey_slack" {
  account_id                = var.account_id
  name                      = "Zoey — Slack webhook"
  type                      = "self_hosted"
  domain                    = "zoey.sargeant.co/api/v1/slack/"
  tags                      = ["Sargeant"]
  app_launcher_visible      = false
  auto_redirect_to_identity = false
}

resource "cloudflare_zero_trust_access_policy" "zoey_slack_bypass" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.zoey_slack.id
  name           = "Slack webhook bypass"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

# --- self_hosted: Diatreme Pro ----------------------------------------------
# The Diatreme Pro dashboard (firefly cluster, behind the firefly cloudflared
# tunnel — ingress in tunnels.tf), served at the apex diatreme.magmamoose.com.
# Superseded Comment Commander Pro, which folded into Diatreme; that app, its
# tunnel ingress and its DNS have all been pruned. The
# dashboard has no in-app auth/paywall yet (MVP), so Access is the only thing
# gating it: Caleb-only. No device-posture `require` — same reasoning as
# Zoey (the posture rules need a WARP-enrolled device
# Caleb doesn't have, so requiring it is a hard lockout; he'll want it on mobile
# too).
#
# Only the dashboard apex is gated. The Diatreme *worker* lives at
# api.diatreme.magmamoose.com and is intentionally NOT behind Access — it's the
# OSS engine API (token broker, /process, /dispatch, /sign, the GitHub webhook,
# OAuth callback) and authenticates callers itself (bearer / HMAC / OIDC).
resource "cloudflare_zero_trust_access_application" "diatreme_pro" {
  account_id                = var.account_id
  name                      = "Diatreme Pro"
  type                      = "self_hosted"
  domain                    = "diatreme.magmamoose.com"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "diatreme_pro_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.diatreme_pro.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}

# --- self_hosted: GitHub Usage Dashboard (firefly) -------------------------
# githubusage.magmamoose.com surfaces org billing usage and has no in-app auth,
# so it's Caleb-only — same posture as the Diatreme Pro dashboard above. The
# tunnel ingress rule is in tunnels.tf; external-dns publishes the CNAME.
resource "cloudflare_zero_trust_access_application" "github_usage_dashboard" {
  account_id                = var.account_id
  name                      = "GitHub Usage Dashboard"
  type                      = "self_hosted"
  domain                    = "githubusage.magmamoose.com"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "github_usage_dashboard_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.github_usage_dashboard.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}

# --- self_hosted: GitHub Contributions (firefly) ---------------------------
# githubcontributions.magmamoose.com surfaces Caleb's personal commit/effort
# analytics across github.com + the PinkRoccade GHES enterprise, and has no
# in-app auth — so it's Caleb-only, same posture as the GitHub Usage Dashboard
# above. The tunnel ingress rule is in tunnels.tf; external-dns publishes the
# CNAME from the k8s Ingress annotations.
resource "cloudflare_zero_trust_access_application" "github_contributions" {
  account_id                = var.account_id
  name                      = "GitHub Contributions"
  type                      = "self_hosted"
  domain                    = "githubcontributions.magmamoose.com"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "github_contributions_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.github_contributions.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}

# --- self_hosted: GitHub Timesheet (firefly) -------------------------------
# uren.calebsargeant.com serves Caleb's reconstructed PinkRoccade "Uren" sheet.
# Unlike the Caleb-only dashboards above, this one is shared with his manager
# Marc Vergunst — so the policy allows the Caleb IdP group OR Marc's email via the
# one_time_pin IdP (Marc has no Google identity in this account; he gets a 6-digit
# code by email). The tunnel ingress rule is in tunnels.tf; external-dns publishes
# the CNAME from the k8s Ingress annotations (calebsargeant.com is in this account).
resource "cloudflare_zero_trust_access_application" "github_timesheet" {
  account_id                = var.account_id
  name                      = "GitHub Timesheet"
  type                      = "self_hosted"
  domain                    = "uren.calebsargeant.com"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "github_timesheet_caleb_marc" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.github_timesheet.id
  name             = "Caleb + Marc"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  # Within one include block the selectors are OR'd: Caleb (via his IdP group)
  # OR Marc (via email-OTP). Marc's address lives in OCI Vault (marc group) so
  # it doesn't appear in this public repo.
  include {
    group = [
      cloudflare_zero_trust_access_group.caleb.id,
      cloudflare_zero_trust_access_group.marc.id,
    ]
  }
}

# --- self_hosted: Diatreme Dispatch API (bypass — bearer-gated) -------------
# diatreme.magmamoose.com/api/dispatch is POSTed to by the Diatreme worker
# (api.diatreme.magmamoose.com) when triage decides a Copilot comment is a
# "fix" — it hands off to the diatreme-pro agent dispatcher. Most-specific path
# first, so /api/dispatch hits this bypass app instead of the Caleb gate on the
# apex dashboard above. The dispatcher authenticates the worker itself (Bearer
# DISPATCH_AGENT_TOKEN) and 503s until configured, so unauthenticated
# reachability is safe here — same reasoning as the Zoey Slack webhook bypass.
# Browser users only ever load the dashboard apex, which stays Caleb-only.
resource "cloudflare_zero_trust_access_application" "diatreme_dispatch" {
  account_id                = var.account_id
  name                      = "Diatreme Dispatch API"
  type                      = "self_hosted"
  domain                    = "diatreme.magmamoose.com/api/dispatch"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = false
  auto_redirect_to_identity = false
}

resource "cloudflare_zero_trust_access_policy" "diatreme_dispatch_bypass" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.diatreme_dispatch.id
  name           = "Worker bypass (bearer-gated)"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

# --- self_hosted: n8n -------------------------------------------------------
# n8n automation platform (firefly cluster, automation ns), now reachable
# off-LAN through the firefly cloudflared tunnel (ingress in tunnels.tf) + the
# proxied CNAME external-dns publishes from kubernetes/apps/n8n's magmamoose
# Ingress. Access is the ZTNA gate: Caleb-only. This covers the editor/UI, the
# self-service ops-request form (/form/operations-request), and the approval
# resume webhooks ($execution.resumeUrl) — so the browser-link approval flow
# works remotely, with Caleb authenticating via Google SSO. No device-posture
# `require` — Caleb approves from his phone too (the posture rules need a
# WARP-enrolled device he doesn't have, so requiring it would be a hard
# lockout). n8n.sargeant.co stays a LAN-only alias (no tunnel, no Access) for
# direct on-LAN access if the edge is down.
#
# The /form, /webhook, and /webhook-waiting paths are carved out below by
# bypass apps so non-Caleb requesters can submit the form and email/Teams/Slack
# approval-link clicks resume without a Google-SSO interstitial. To let other
# @magmamoose.com staff submit the form OR access the editor/UI, swap this
# policy's group to cloudflare_zero_trust_access_group.magma_moose_domain.
resource "cloudflare_zero_trust_access_application" "n8n" {
  account_id                = var.account_id
  name                      = "n8n"
  type                      = "self_hosted"
  domain                    = "n8n.magmamoose.com"
  logo_url                  = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/n8n.svg"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "n8n_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.n8n.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}

# Bypass apps for n8n's public form + webhook paths. Cloudflare Access matches
# the most-specific path first, so requests under /form/, /webhook/, and
# /webhook-waiting/ hit these bypass apps instead of the Caleb gate above.
# Three reasons we need them:
#   1. /form/<id>         — the self-service ops-request form (and any future
#                           Form Triggers) is submitted by non-technical users
#                           who don't have Cloudflare Access. Without bypass,
#                           the form URL forces Google SSO and they can't pass.
#   2. /webhook-waiting/  — the Wait-node resume URL ($execution.resumeUrl),
#                           clicked from email/Teams/Slack approval messages.
#                           Bypassing makes the click an instant resume instead
#                           of a Google-SSO interstitial; security relies on the
#                           per-execution unique resume token (UUID).
#   3. /webhook/<id>      — for any future Webhook-trigger workflows. n8n's
#                           webhook authentication options (header/JWT/HMAC) are
#                           configured per-node and authenticate the caller
#                           themselves; same model as the Zoey/Diatreme bypasses.
# The n8n editor/UI/API stay behind the Caleb gate via the apex domain match.
# Three separate apps (one per path) — provider v4 deprecated multi-domain apps
# and the existing Zoey/Diatreme bypasses follow this same one-app-per-path
# pattern.
resource "cloudflare_zero_trust_access_application" "n8n_form" {
  account_id                = var.account_id
  name                      = "n8n — Form trigger"
  type                      = "self_hosted"
  domain                    = "n8n.magmamoose.com/form/"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = false
  auto_redirect_to_identity = false
}

resource "cloudflare_zero_trust_access_policy" "n8n_form_bypass" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.n8n_form.id
  name           = "Form bypass"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

resource "cloudflare_zero_trust_access_application" "n8n_webhook_waiting" {
  account_id                = var.account_id
  name                      = "n8n — Wait resume webhook"
  type                      = "self_hosted"
  domain                    = "n8n.magmamoose.com/webhook-waiting/"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = false
  auto_redirect_to_identity = false
}

resource "cloudflare_zero_trust_access_policy" "n8n_webhook_waiting_bypass" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.n8n_webhook_waiting.id
  name           = "Wait resume bypass"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

resource "cloudflare_zero_trust_access_application" "n8n_webhook" {
  account_id                = var.account_id
  name                      = "n8n — Webhook trigger"
  type                      = "self_hosted"
  domain                    = "n8n.magmamoose.com/webhook/"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = false
  auto_redirect_to_identity = false
}

resource "cloudflare_zero_trust_access_policy" "n8n_webhook_bypass" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.n8n_webhook.id
  name           = "Webhook bypass"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

# --- self_hosted: n8n-mcp (service-token-gated path on the n8n host) ---------
# The n8n-mcp remote MCP server (kubernetes/apps/n8n-mcp) — lets Claude Code /
# Claude Desktop build & edit n8n workflows via prompts. It runs in the firefly
# cluster and talks to n8n over the cluster network
# (n8n.automation.svc:5678/api/v1), so n8n's own REST API NEVER goes public — it
# stays behind the Caleb SSO gate on the n8n.magmamoose.com apex. This carves out
# the /mcp PATH on that same host (most-specific match wins, like the /form +
# /webhook bypasses above) and gates it with a Cloudflare Access service token
# (non-human identity). Defence in depth:
#   edge   — CF Access service token (CF-Access-Client-Id / -Secret)  ← this app
#   app    — the MCP's own bearer (AUTH_TOKEN, Authorization: Bearer …)
#   origin — n8n's X-N8N-API-KEY (in-cluster only, never leaves the namespace)
# No human SSO policy: a browser can't speak the MCP protocol anyway, the only
# client is the machine token. NOTE: CF Access path-matching is a prefix, so this
# also gates n8n's own native MCP-trigger production URLs (/mcp/<id>); the
# /webhook/mcp/<id> trigger form is unaffected (covered by the /webhook bypass).
# The firefly tunnel routes n8n.magmamoose.com ^/mcp to the MCP (tunnels.tf).
resource "cloudflare_zero_trust_access_application" "n8n_mcp" {
  account_id                = var.account_id
  name                      = "n8n-mcp"
  type                      = "self_hosted"
  domain                    = "n8n.magmamoose.com/mcp"
  logo_url                  = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/n8n.svg"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = false
  auto_redirect_to_identity = false
  session_duration          = "24h"
}

resource "cloudflare_zero_trust_access_policy" "n8n_mcp_service_token" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.n8n_mcp.id
  name           = "n8n-mcp service token"
  decision       = "non_identity"
  precedence     = 1

  include {
    service_token = [cloudflare_zero_trust_access_service_token.n8n_mcp.id]
  }
}

# ---------------------------------------------------------------------------
# Grafana — kube-prometheus-stack observability dashboards (firefly cluster).
# Reachable off-LAN via the firefly cloudflared tunnel (tunnels.tf) and gated by
# this Caleb-only Access app. The tunnel route + the proxied CNAME external-dns
# publishes from kubernetes/apps/kube-prometheus-stack replace the old private
# LAN A record that hung from off-LAN. grafana.sargeant.local stays LAN-only
# (no tunnel, no Access). Grafana keeps its own login behind Access.
# ---------------------------------------------------------------------------
resource "cloudflare_zero_trust_access_application" "grafana" {
  account_id                = var.account_id
  name                      = "Grafana"
  type                      = "self_hosted"
  domain                    = "grafana.magmamoose.com"
  logo_url                  = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/grafana.svg"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "grafana_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.grafana.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}

# ---------------------------------------------------------------------------
# AppSec / dev tooling — SonarQube, Dependency-Track.
#
# These hostnames were publicly tunnelled with NO edge gate and no oauth2-proxy.
# Verified unauthenticated from the internet on 2026-07-24: sonarqube 200 (and
# /api/system/status 200 — a version banner), dependencytrack 200,
# dependencytrack-api 401.
#
# SonarQube force-auth and Dependency-Track both 401 their data APIs, so nothing
# sensitive was anonymously readable; this is defence in depth plus keeping login
# pages and version banners away from drive-by scanning.
#
# The Backstage app this change originally carried is gone: Backstage is no
# longer deployed on the cluster, and an Access app for a hostname with no
# tunnel ingress behind it is dead config.
# ---------------------------------------------------------------------------

# --- SonarQube --------------------------------------------------------------
# Whole host, no path carve-out. NOTHING pushes to SonarQube over the public
# hostname: the DefectDojo importer (sonarqube-defectdojo-sync in
# kubernetes/apps/security-integrations) uses the in-cluster Service
# http://sonarqube-sonarqube.security.svc.cluster.local:9000, and that same URL
# is what the CronJob writes into DefectDojo's Tool Configuration.
# If CI analysis is ever added, run sonar-scanner on the in-cluster `firefly`
# self-hosted runner against that cluster Service. Do NOT add a bypass here —
# sonar-scanner cannot send CF-Access-Client-Id/-Secret headers, and a bypass on
# /api/ would re-expose the entire SonarQube API.
resource "cloudflare_zero_trust_access_application" "sonarqube" {
  account_id                = var.account_id
  name                      = "SonarQube"
  type                      = "self_hosted"
  domain                    = "sonarqube.magmamoose.com"
  logo_url                  = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/sonarqube.svg"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "sonarqube_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.sonarqube.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}


# --- Dependency-Track UI ----------------------------------------------------
# The tunnel splits this ONE hostname: `^/api(/|$)` goes to the apiserver and
# everything else to the frontend SPA (which is same-origin — its
# /static/config.json API_BASE_URL is this apex, not the -api host).
# The `/api` prefix is deliberately carved out below for CI, so this app gates
# the UI only. Precedence matters: Cloudflare evaluates the most specific
# domain first, so the /api bypass wins for API paths.
resource "cloudflare_zero_trust_access_application" "dependency_track" {
  account_id                = var.account_id
  name                      = "Dependency-Track"
  type                      = "self_hosted"
  domain                    = "dependencytrack.magmamoose.com"
  logo_url                  = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/dependency-track.svg"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  session_duration          = "24h"

  allowed_idps = [
    cloudflare_zero_trust_access_identity_provider.google_workspace.id,
    cloudflare_zero_trust_access_identity_provider.one_time_pin.id,
    cloudflare_zero_trust_access_identity_provider.google.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "dependency_track_caleb" {
  account_id       = var.account_id
  application_id   = cloudflare_zero_trust_access_application.dependency_track.id
  name             = "Caleb"
  decision         = "allow"
  precedence       = 1
  session_duration = "24h"

  include {
    group = [cloudflare_zero_trust_access_group.caleb.id]
  }
}

# --- Dependency-Track /api — DELIBERATE BYPASS (load-bearing for CI) --------
# The chargate reusable action uploads SBOMs to
# https://dependencytrack.magmamoose.com/api/v1/bom on every merge to main, and
# READS /api/* on pull_request events. It has no CF-Access-header input, so it
# cannot authenticate to Access — an identity policy here breaks release CI for
# every repo using the action.
#
# This is NOT an open door: Dependency-Track enforces its own X-Api-Key on every
# /api call (verified: /api/v1/project returns 401 unauthenticated). The bypass
# only means "let Cloudflare pass this through and let the app authenticate it".
#
# `/api` with NO trailing slash on purpose — the tunnel routes bare `GET /api`
# to the apiserver too, and `/api/` would not match it.
resource "cloudflare_zero_trust_access_application" "dependency_track_api_path" {
  account_id           = var.account_id
  name                 = "Dependency-Track API (CI bypass)"
  type                 = "self_hosted"
  domain               = "dependencytrack.magmamoose.com/api"
  tags                 = ["Magma Moose"]
  app_launcher_visible = false
}

resource "cloudflare_zero_trust_access_policy" "dependency_track_api_path_bypass" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.dependency_track_api_path.id
  name           = "Bypass — app enforces X-Api-Key"
  decision       = "bypass"
  precedence     = 1

  include {
    everyone = true
  }
}

# --- Dependency-Track API host (legacy) -------------------------------------
# dependencytrack-api.magmamoose.com is a leftover from when the SPA was thought
# to need a separate API origin. It is same-origin now and this hostname has no
# known caller, so it is gated by service token ONLY — no browser SSO policy, so
# it cannot become a UI back door. Slated for removal; until then it is closed.
resource "cloudflare_zero_trust_access_application" "dependency_track_api_host" {
  account_id                = var.account_id
  name                      = "Dependency-Track API (host)"
  type                      = "self_hosted"
  domain                    = "dependencytrack-api.magmamoose.com"
  tags                      = ["Magma Moose"]
  app_launcher_visible      = false
  session_duration          = "24h"
  service_auth_401_redirect = true
}

resource "cloudflare_zero_trust_access_policy" "dependency_track_api_host_token" {
  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.dependency_track_api_host.id
  name           = "Service token only"
  decision       = "non_identity"
  precedence     = 1

  include {
    service_token = [cloudflare_zero_trust_access_service_token.dependency_track_api.id]
  }
}
