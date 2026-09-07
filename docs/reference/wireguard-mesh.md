# WireGuard mesh between the router sites

Ten point-to-point WireGuard tunnels join the five MikroTik routers across three sites. It is the
transport that lets the two OCI environments reach each other; before it existed they had no path
between them at all.

Source: [`terraform/mikrotik/wireguard-mesh/prod`](https://github.com/MagmaMoose/infra/tree/main/terraform/mikrotik/wireguard-mesh/prod)
driving `terraform/mikrotik/modules/wireguard-mesh`. Background and the reasoning behind each
choice: ADR `2026-09-01-wireguard-mesh-between-router-sites`.

## Sites and routers

| Router | Site | Network behind it | API host | WireGuard endpoint |
| --- | --- | --- | --- | --- |
| `ff-crs1` | Home (Sargeant House) | `192.168.19.0/24` | `192.168.19.1` | none — behind FG1 |
| `ff-chr1` | calebsargeant OCI | `192.168.223.0/24` | `134.98.139.9` | `134.98.139.9` |
| `ff-chr2` | calebsargeant OCI | `192.168.223.0/24` | `193.123.39.172` | `193.123.39.172` |
| `ff-chr3` | traceysargeant OCI | `192.168.240.0/24` | `158.178.154.125` | `158.178.154.125` |
| `ff-chr4` | traceysargeant OCI | `192.168.240.0/24` | `84.235.162.6` | `84.235.162.6` |

`ff-crs1` has no endpoint on purpose. It sits behind FG1 with no port forward for these ports, so
it is the **initiator** on all four of its tunnels and nothing ever dials it. The six OCI-to-OCI
tunnels have `initiator = "both"`: two static public IPs, so either end can recover on its own.

## Tunnels

Every unordered pair. Transit is `192.168.255.0/26` carved into /30s; `a` takes `.1`, `b` takes
`.2`.

| Tunnel | a | b | Transit | Port on a | Port on b |
| --- | --- | --- | --- | --- | --- |
| `crs1-chr1` | ff-crs1 | ff-chr1 | `192.168.255.0/30` | 51841 | **51820** |
| `crs1-chr2` | ff-crs1 | ff-chr2 | `192.168.255.4/30` | 51842 | **51820** |
| `crs1-chr3` | ff-crs1 | ff-chr3 | `192.168.255.8/30` | 51843 | **51820** |
| `crs1-chr4` | ff-crs1 | ff-chr4 | `192.168.255.12/30` | 51844 | **51820** |
| `chr1-chr2` | ff-chr1 | ff-chr2 | `192.168.255.16/30` | 51845 | 51845 |
| `chr1-chr3` | ff-chr1 | ff-chr3 | `192.168.255.20/30` | 51846 | 51846 |
| `chr1-chr4` | ff-chr1 | ff-chr4 | `192.168.255.24/30` | 51847 | 51847 |
| `chr2-chr3` | ff-chr2 | ff-chr3 | `192.168.255.28/30` | 51848 | 51848 |
| `chr2-chr4` | ff-chr2 | ff-chr4 | `192.168.255.32/30` | 51849 | 51849 |
| `chr3-chr4` | ff-chr3 | ff-chr4 | `192.168.255.36/30` | 51850 | 51850 |

**The four `51820`s are load-bearing.** The home edge only passes certain outbound UDP destination
ports; 51841-51844 are not among them, and a tunnel using them handshakes never — `tx` climbs,
`rx` stays at zero on both ends. Each CHR can bind 51820 because each has exactly one tunnel to
`ff-crs1`. `ff-crs1`'s own port is a source port and nothing filters on it.

## Routing

Only the OCI-to-OCI leg carries production traffic.

```
pod on ff-oci1 ──▶ VCN rt-app (192.168.240.0/24 → ff-chr1)
                        │
                   ff-chr1 ──▶ wg-ff-chr3 ──▶ ff-chr3
                                                  │
                                    VCN rt-app (192.168.223.0/24 ← ff-chr3)
                                                  ▼
                                            pod on ff-oci3
```

The VCN half is `via = "chr"` on the `cloudworkers_vcn` / `firefly_vcn` entries in each `network`
leaf's `remote_networks`. The CHR half is the `routes` block in the mesh leaf:

| Router | Destination | Primary | Standby |
| --- | --- | --- | --- |
| ff-chr1 | `192.168.240.0/24` | via ff-chr3 (d1) | via ff-chr4 (d2) |
| ff-chr2 | `192.168.240.0/24` | via ff-chr3 (d1) | via ff-chr4 (d2) |
| ff-chr3 | `192.168.223.0/24` | via ff-chr1 (d1) | via ff-chr2 (d2) |
| ff-chr4 | `192.168.223.0/24` | via ff-chr1 (d1) | via ff-chr2 (d2) |

`ff-chr1 <-> ff-chr3` is primary because both VCNs set `internet_gateway_ip` to `.11`. The
mirror-image routes on `.12` exist so that promoting the standby is a one-line VCN route-table
edit with a tunnel already up behind it.

**`ff-crs1` installs no prefix routes.** Home to OCI still runs over FG1's IPSec. A `/24` beats the
default route regardless of distance, so adding one here would divert that traffic immediately;
moving it is a deliberate change, not a side effect. The home tunnels exist, are kept warm, and
can be verified by pinging the far transit address.

**Pod and service CIDRs are not routed over the mesh.** Pod-to-pod between environments is flannel
VXLAN between *node* addresses, so routing the two /24s is enough. Both VCNs keep handing
`10.42.0.0/16` and `10.43.0.0/16` to their DRG for on-prem traffic.

## Keys

Private keys are generated on the routers — `routeros_interface_wireguard.private_key` is left
unset — and the provider reads back only `public_key`, which the far end's peer resource
references. No WireGuard key material is in this repo, and none has to be moved between the two
Oracle accounts by hand.

Router admin passwords come from OCI Vault (`vault-prod`): `mikrotik-credentials` for
ff-crs1/ff-chr1/ff-chr2, `mikrotik-credentials-cloudworkers` for ff-chr3/ff-chr4. The two OCI
environments are separate Oracle accounts and deliberately do not share a password.

## Applying

```bash
cd terraform/mikrotik/wireguard-mesh/prod
terragrunt apply
```

Atlantis autoplan is disabled (project `mikrotik-wireguard-mesh-prod`): a plan opens a live
RouterOS session to all five routers and resolves both passwords through parse-time vault lookups.

**Order matters across leaves, and Atlantis does not model it.** Apply this leaf *before* either
`network` leaf, because those route the far tenancy's /24 at their local CHR — do it the other way
round and the route points at a CHR with nowhere to send the packet, which bounces it back into
the VCN it came from.

## Checking it

```bash
# every peer should show a recent handshake and non-zero rx
/interface/wireguard/peers print detail where interface~"wg-"

# every mesh route should be active=yes on the primary, inactive on the standby
/ip/route print where comment~"wireguard-mesh"
```

`rx = 0` on a peer means the network never delivered the packets — look at the path, not at
WireGuard. A peer with a healthy handshake but `active=no` on its route means the far router is
dropping the `check-gateway` ICMP; the mesh transit range must be in that router's `TRUSTED`
address list.

End-to-end, from the cluster:

```bash
kubectl -n default run t --image=busybox:1.37.0 --restart=Never \
  --overrides='{"spec":{"nodeName":"ff-oci1"}}' -- sleep 300
kubectl exec t -- ping -c3 <pod IP on ff-oci3>
```

## Known gaps

- No preshared keys. WireGuard's handshake is secure without them; a PSK is a post-quantum hedge.
- ff-chr3 and ff-chr4 have **no firewall filter rules at all**, and their subnet's security list
  admits ssh/http/https/winbox from `0.0.0.0/0`. A cloudworkers `mikrotik` leaf is the fix.
- If both tunnels from a CHR are down, `check-gateway` withdraws its routes and the CHR falls back
  to its default route — into the VCN, which routes the prefix straight back to it. TTL-bounded,
  and only while a whole site is unreachable, but real.
- `ff-crs1` still carries `oci-r1` and `oci-r2` from an earlier attempt: running, zero bytes,
  pointing at a public IP that no longer belongs to anything. Dead config that reads like a
  working tunnel.
