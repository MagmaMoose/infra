<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | ~> 4.40 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | 4.52.7 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.9.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cloudflare_zero_trust_access_application.app_launcher](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.aws_magmamoose](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.aws_platform_1](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.comment_commander_pro](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.diatreme_dispatch](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.diatreme_pro](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.overseerr](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.radarr](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.warp_login](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.zoey](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_application.zoey_slack](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application) | resource |
| [cloudflare_zero_trust_access_group.caleb](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_group) | resource |
| [cloudflare_zero_trust_access_group.caleb_personal](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_group) | resource |
| [cloudflare_zero_trust_access_group.friends](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_group) | resource |
| [cloudflare_zero_trust_access_group.household](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_group) | resource |
| [cloudflare_zero_trust_access_group.marc](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_group) | resource |
| [cloudflare_zero_trust_access_group.magma_moose_domain](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_group) | resource |
| [cloudflare_zero_trust_access_identity_provider.google](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_identity_provider) | resource |
| [cloudflare_zero_trust_access_identity_provider.google_workspace](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_identity_provider) | resource |
| [cloudflare_zero_trust_access_identity_provider.one_time_pin](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_identity_provider) | resource |
| [cloudflare_zero_trust_access_policy.app_launcher_magma](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.comment_commander_pro_caleb](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.diatreme_dispatch_bypass](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.diatreme_pro_caleb](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.overseerr_caleb](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.overseerr_friends](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.radarr_caleb](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.radarr_friends](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.warp_allow_emails](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.warp_email_domain](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.zoey_caleb](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_access_policy.zoey_slack_bypass](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_policy) | resource |
| [cloudflare_zero_trust_device_posture_rule.mac_disk_encryption](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_device_posture_rule) | resource |
| [cloudflare_zero_trust_device_posture_rule.mac_firewall](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_device_posture_rule) | resource |
| [cloudflare_zero_trust_device_posture_rule.mac_os_version](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_device_posture_rule) | resource |
| [cloudflare_zero_trust_device_profiles.default](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_device_profiles) | resource |
| [cloudflare_zero_trust_gateway_policy.block_adware](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_gateway_policy) | resource |
| [cloudflare_zero_trust_split_tunnel.default_exclude](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_split_tunnel) | resource |
| [cloudflare_zero_trust_tunnel_cloudflared.firefly](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_tunnel_cloudflared) | resource |
| [cloudflare_zero_trust_tunnel_cloudflared.firefly_oci](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_tunnel_cloudflared) | resource |
| [cloudflare_zero_trust_tunnel_cloudflared_config.firefly](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_tunnel_cloudflared_config) | resource |
| [cloudflare_zero_trust_tunnel_cloudflared_config.firefly_oci](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_tunnel_cloudflared_config) | resource |
| [cloudflare_zero_trust_tunnel_route.rfc1918_10](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_tunnel_route) | resource |
| [cloudflare_zero_trust_tunnel_route.rfc1918_172](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_tunnel_route) | resource |
| [cloudflare_zero_trust_tunnel_route.rfc1918_192](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_tunnel_route) | resource |
| [random_password.firefly_oci_tunnel_secret](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | Cloudflare account ID (Zero Trust org) | `string` | n/a | yes |
| <a name="input_cf_access_groups_membership"></a> [cf\_access\_groups\_membership](#input\_cf\_access\_groups\_membership) | Email member lists for each Access group, sourced from OCI Vault by the terragrunt parse-time run\_cmd (see terragrunt.hcl). Kept out of git so the public repo doesn't list family/friends' personal addresses (PII). | <pre>object({<br/>    friends        = list(string)<br/>    caleb          = list(string)<br/>    household      = list(string)<br/>    caleb_personal = list(string)<br/>    marc           = list(string)<br/>  })</pre> | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_firefly_oci_tunnel_id"></a> [firefly\_oci\_tunnel\_id](#output\_firefly\_oci\_tunnel\_id) | Tunnel ID for firefly-oci. Needed for the cfargotunnel CNAME if/when OCI-side hostnames are added. |
<!-- END_TF_DOCS -->
