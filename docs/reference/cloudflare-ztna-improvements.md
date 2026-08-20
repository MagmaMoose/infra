# Cloudflare ZTNA Improvement Backlog

Captured during the initial dashboard→terraform import (see
`terraform/cloudflare/zero-trust/prod/`). None of these are required for the
import to land; each is a discrete follow-up PR.

Ranked roughly by impact × effort, highest first.

## 1. Promote Radarr from `bookmark` to `self_hosted` (security gap)

Today the Radarr Access "app" is `type = "bookmark"`. Bookmarks are **not
authenticated**. They're just an icon in the App Launcher; the actual
service at `radarr.sargeant.co` is reachable by anyone with the URL.
Overseerr is correctly `self_hosted`. Either:

- Promote Radarr to `self_hosted` with a `Friends` policy (same emails as
  Overseerr) and a Caleb override; or
- Remove the bookmark if Radarr is intentionally public.

Either way, the current state is the worst of both worlds: Access shows it
in the launcher but doesn't actually protect it.

**Pairing required:** promotion only works if the `firefly` cloudflared
tunnel also has an ingress rule for `radarr.sargeant.co`. Today the
ingress config has just `overseerr.sargeant.co` → `http://overseerr...`
and a 404 catch-all. Step-by-step:

1. Add a `cloudflare_zero_trust_tunnel_cloudflared_config` ingress_rule
   for `radarr.sargeant.co` pointing at the actual radarr URL (likely
   `http://radarr.media.svc.cluster.local:7878` if it's in the firefly
   k3s cluster, but verify, since the OCI cloudflared can only resolve
   `.svc.cluster.local` if it's somehow joined to the cluster's DNS).
2. Flip Radarr's `type` to `self_hosted` and attach a policy.
3. Drop the existing `bookmark` resource (or keep as a managed
   bookmark, distinct from the self_hosted entry).

## 2. Fix r1's cloudflared HA (availability gap)

**Resolved 2026-05-19.** r1's container had been stopped since 2026-05-11
(stale ingress config caused cloudflared to crash; `auto-restart-interval`
defaulted to `none`, so RouterOS never restarted it). Started manually via
the API; `auto-restart-interval` set to `30s` on r1 so it self-heals next
time. r2 took the load all that time.

Both routers now active: 8 colo connections to the `firefly` tunnel (4
each, full HA). Cloudflare reports `status: healthy`.

**Residual gap: r2 firmware** doesn't accept the `auto-restart-interval`
parameter (older RouterOS schema; `unknown parameter` error from the API).
If r2's cloudflared crashes, it won't auto-restart. Two options:

- Upgrade r2's RouterOS firmware to match r1, then set the same 30s
  interval. Cleanest.
- Add a RouterOS `/system/scheduler` job on r2 that runs every minute and
  starts the cloudflared container if it's stopped. Works on older
  firmware. Copy-paste-safe script (matches the container by `name`; the
  container name is `cloudflared:latest`, derived from `remote_image`):

  ```routeros
  /system/scheduler/add \
    name=cloudflared-watchdog \
    interval=1m \
    on-event=":local cid [/container find where name=\"cloudflared:latest\"]; :if ([:len \$cid] = 1 && [/container get \$cid stopped] = true) do={ /container start \$cid; :log info \"cloudflared-watchdog: started stopped container\" }"
  ```

  Codify this in the mikrotik terraform module via a `routeros_system_scheduler`
  resource, gated by an input that defaults off but is enabled for r2.

## 3. Extract repeated email lists into Access Groups

**Done.** Four Access Groups in `access_groups.tf`: `friends`, `caleb`,
`household`, `magma_moose_domain`. The four affected policies
(`overseerr_friends`, `overseerr_caleb`, `warp_allow_emails`,
`app_launcher_magma`) had to be recreated as app-scoped first because
the imported originals were reusable in CF and the v4 provider returns
error 12130 when updating reusable policies via the app-scoped endpoint.

Cutover that landed this work:
1. Detached all policies from each affected app via
   `PUT /accounts/<acct>/access/apps/<id>` with `policies: []`.
2. `DELETE /accounts/<acct>/access/policies/<id>` on each old reusable
   policy.
3. `terraform state rm` the 5 policy resources (the 4 reusable plus
   `warp_email_domain`, which was incidentally detached in step 1).
4. `terragrunt apply` recreated all 5 policies as `reusable: false` with
   group-based includes and (for `overseerr_caleb`) the posture
   `require` block (see #4).

Access gap was ~30s between detach and apply; affected apps denied all
requests during that window.

## 4. Wire device posture rules into Access policies

**Done as part of #3.** `overseerr_caleb` now carries:

```hcl
require {
  device_posture = [
    cloudflare_zero_trust_device_posture_rule.mac_disk_encryption.id,
    cloudflare_zero_trust_device_posture_rule.mac_os_version.id,
  ]
}
```

Caleb's session is only valid from a macOS device with FileVault on and
OS version ≥ 13.0.1. Firewall posture rule intentionally not required
(many dev Macs have the system firewall off). Friends policy stays
posture-less so mixed-device family/friends aren't locked out.

## 5. Move tunnel credentials into OCI Vault

Today the cloudflared tunnel token lives in 1Password (`Firefly Cloudflare
Tunnel Token`) and gets injected into the MikroTik container env at
terragrunt parse time via `op read`. The new pattern (matching the
cloudflare API token) is to keep all secrets in OCI Vault and read via the
oci CLI.

After this migration:
- One source of truth for secrets (OCI Vault)
- 1Password dependency drops out of the mikrotik terragrunt
- Rotation is `oci vault secret update-base64`, no app re-deploy needed
  (when paired with a small `cloudflared`-watching reload mechanism)

## 6. Service tokens for automation paths

**Scaffold landed.** `terraform/cloudflare/zero-trust/prod/service_tokens.tf`
documents the pattern (commented-out example resource + matching
non_identity policy + outputs for `client_id` / `client_secret`). No
service tokens are actually defined yet. Add the first one when there's
a real consumer (e.g. uptime monitoring hitting `overseerr.sargeant.co`).

Workflow once a token is added:

1. `terragrunt apply`
2. `terraform output -raw service_token_<name>_client_secret` (sensitive,
   only available at create-time)
3. Stash in OCI Vault (or pipe directly into the consumer's secret store)
4. Caller sends `CF-Access-Client-Id` + `CF-Access-Client-Secret` headers

## 7. Replace the manual adware list with CF managed categories

**Blocked: Zero Trust tier.** Discovered via
`GET /accounts/<acct>/gateway/categories`: the categories that would
replace the manual adware list (`Ads`, `Deceptive Ads`, plus broader
`Trackers` / `Adult Themes`-adjacent things) are all `class: "premium"`
on this account. Only `Adult Themes` and `Security threats` are `free`.

Options:

- Stay with the manual list (current state, keeps zero recurring cost).
- Upgrade to a Zero Trust paid seat / plan that includes the premium
  categories, then swap `traffic = "any(dns.domains[*] in {…})"` to
  `traffic = "any(dns.content_category[*] in {1, 4, …})"` using the IDs
  returned by the categories endpoint.

## 8. Document or consolidate the L4 allow + block rules on `192.168.69.110`

**Resolved: deleted as dead code.** The pair was leftover from the
dashboard→terraform import (#199), policing traffic to a Franklin Cape
Town server (`.110` on the same `192.168.69.0/24` segment as the Franklin
hosts in `ansible/hosts.yaml`). Operator confirmed both rules were
unintentional carry-over: actual access to `.110` already goes via the
on-prem MikroTik VPN + DRG peering, not through Cloudflare WARP, so the
Gateway rules had no data-plane effect. Removed in the same PR that
records this resolution; `gateway.tf` keeps a one-paragraph comment
where the rules used to live so a future operator reading git blame
sees the deletion rationale.

## 9. Rename the "firefly" tunnel to something OCI-specific

**Needs scheduled cutover, not a quick fix.** Tunnel name is immutable
post-creation; the rename is actually a recreate + cutover:

1. `cloudflare_zero_trust_tunnel_cloudflared "magmamoose_oci"` defined in
   addition to the existing `firefly` (don't replace yet).
2. New tunnel token issued; push to both MikroTik cloudflared containers
   via the existing OCI Vault flow.
3. Migrate ingress configuration to the new tunnel
   (`cloudflare_zero_trust_tunnel_cloudflared_config "magmamoose_oci"`).
4. Wait for the new tunnel to register healthy connections from both
   routers.
5. Delete the `firefly` tunnel and its ingress config.

Expected window of disruption: ~30s while cloudflared restarts with the
new token on each router (do them sequentially so the old tunnel keeps
serving until the new one is up). Schedule in a low-traffic window.

## 10. Browser isolation for risky apps

**Blocked: Zero Trust tier.** Browser isolation is a paid CF Zero Trust
feature. Same blocker as #7: needs a Zero Trust plan upgrade. Once
unlocked, the implementation is a `cloudflare_zero_trust_gateway_policy`
with `action = "isolate"` (HTTP filter) targeting the relevant
hostnames, e.g.:

```hcl
resource "cloudflare_zero_trust_gateway_policy" "isolate_overseerr" {
  account_id = var.account_id
  name       = "Isolate overseerr"
  action     = "isolate"
  filters    = ["http"]
  precedence = 17000
  traffic    = "http.request.host == \"overseerr.sargeant.co\""
}
```

## 11. WARP profile / device enrollment policy in terraform

**Resolved default profile & split tunnels 2026-06-09.** We have successfully codified the default device profile (`cloudflare_zero_trust_device_profiles.default`) and split tunnel exclude rules (`cloudflare_zero_trust_split_tunnel.default_exclude`) under `terraform/cloudflare/zero-trust/prod/`. This includes directing RFC1918 traffic (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) to the `firefly` tunnel, allowing private network routing while allowing local subnet bypass.

**Remaining scopes (future PRs):**
- Add a posture-restricted profile for Caleb-only that includes the posture rules (FileVault + OS version) on top of the default.
- Reference the existing `magma_moose_domain` access group in the enrolment policy so only `@magmamoose.com` emails can register.

## 12. Logpush for Access + Gateway events

**Likely blocked on tier.** Logpush historically required an Enterprise
plan; the Zero Trust paid tier may include limited Logpush. Confirm in
the CF dashboard before terraform work.

Once available, the implementation is two pieces:

1. **GCS destination** (separate bucket `sargeant-prod-cf-logs` or similar
   in `magmamoose-terraform`, with a dedicated service account granted
   `storage.objectCreator`).
2. **Logpush jobs**, one per dataset you want, via
   `cloudflare_logpush_job`:

   ```hcl
   resource "cloudflare_logpush_job" "access_requests" {
     account_id          = var.account_id
     name                = "access-requests"
     dataset             = "access_requests"
     destination_conf    = "gs://sargeant-prod-cf-logs/access/{DATE}?cf-cred-key=...&format=ndjson"
     enabled             = true
     logpull_options     = "fields=AccessRequestID,AccountID,Action,AppDomain,AppUUID,Country,CreatedAt,Email,IPAddress,RayID,UserUID&timestamps=rfc3339"
   }
   ```

3. (Optional) `gateway_dns`, `gateway_http`, `gateway_network` datasets
   for the gateway side.
