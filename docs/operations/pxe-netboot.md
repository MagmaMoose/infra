# PXE netboot workers

Any x86_64 UEFI machine on the home LAN can network-boot into a RAM-only Fedora CoreOS
and join firefly as a k3s agent. Nothing is installed: the machine's own disks are
never read or written, and the next normal boot brings back whatever OS it had.

## How a boot goes

```text
firmware PXE ──DHCP──▶ ff-crs1        next-server 192.168.19.11, file shimx64.efi
         ──TFTP──▶ ff-pi2:69          shimx64.efi → grubx64.efi → grub.cfg
GRUB     ──HTTP──▶ ff-pi2:8069        fcos/kernel, fcos/initramfs.img
initramfs──HTTP──▶ ff-pi2:8069        fcos/rootfs.img, ignition/worker.ign (LAN only)
Ignition ──HTTP──▶ ff-pi2:8069        k3s/k3s (sha256-pinned)
k3s agent──HTTPS─▶ ff-pi1:6443        joins with an agent-only bootstrap token
```

Everything on ff-pi2 is the `pxe-netboot` Deployment in `networking`
(`kubernetes/apps/pxe-netboot`). It uses `hostNetwork` because TFTP does not survive a
Service or NAT, and it is pinned to ff-pi2 by hostname because the router hands out
that node's IP. Its init container downloads and verifies everything on every pod
start (~1GB, a few minutes):

| What | Source | Verified by |
|---|---|---|
| FCOS live kernel, initramfs, rootfs | `coreos-installer download`, stream `stable` | Fedora GPG signature |
| `shimx64.efi`, `grubx64.efi`, `mmx64.efi` | Fedora `shim-x64`, `grub2-efi-x64` RPMs | `rpmkeys --checksig` |
| `k3s` | GitHub release `K3S_VERSION` | `K3S_SHA256` (again by Ignition at boot) |
| `core` user SSH keys | `github.com/<SSH_KEYS_GITHUB_USER>.keys` | TLS only |

Restarting the pod picks up a new FCOS stable release and new shim/GRUB builds.

## Secure Boot

The chain is signed end to end: Microsoft's UEFI CA signs Fedora's shim, shim checks
Fedora's GRUB, and GRUB checks the Fedora-signed FCOS kernel. A machine whose firmware
settings are locked can boot it with Secure Boot left on.

The exception: some business laptops ship with the **Microsoft third-party UEFI CA
disabled** (often labelled "Secured-core" or "Allow Microsoft 3rd Party UEFI CA").
Those refuse every Linux shim, and only someone with the firmware password can change
that. The symptom is a Secure Boot violation right after `shimx64.efi` downloads.

## DHCP on ff-crs1

Not managed from this repo (RouterOS 7.22.3, applied over SSH). The boot file goes
only to clients whose vendor class says x86_64 UEFI PXE, through a matcher and an
option set. Every client gets `next-server`, which non-PXE clients ignore.

```routeros
/ip dhcp-server option add name=pxe-uefi-x64-bootfile code=67 value="s'shimx64.efi'" force=yes comment="pxe-netboot: firefly"
/ip dhcp-server option sets add name=pxe-uefi-x64 options=pxe-uefi-x64-bootfile comment="pxe-netboot: firefly"
/ip dhcp-server matcher add name=pxe-uefi-x64-arch7 server=server1 address-pool=sargeant code=60 matching-type=substring value="PXEClient:Arch:00007" option-set=pxe-uefi-x64 comment="pxe-netboot: firefly"
/ip dhcp-server matcher add name=pxe-uefi-x64-arch9 server=server1 address-pool=sargeant code=60 matching-type=substring value="PXEClient:Arch:00009" option-set=pxe-uefi-x64 comment="pxe-netboot: firefly"
/ip dhcp-server network set [find address=192.168.19.0/24] next-server=192.168.19.11
```

- **`address-pool=sargeant` is mandatory.** A matcher defaults to `static-only`, which
  would leave every PXE client without an address unless it has a static lease.
- EDK2 firmware takes the TFTP server from `next-server` (siaddr), not from option 66,
  so that has to be on the network entry.
- Lockout risk: none for management. Only DHCP clients that announce `PXEClient` are
  affected, and existing leases are untouched.

Remove it all:

```routeros
/ip dhcp-server matcher remove [find comment="pxe-netboot: firefly"]
/ip dhcp-server option sets remove [find comment="pxe-netboot: firefly"]
/ip dhcp-server option remove [find comment="pxe-netboot: firefly"]
/ip dhcp-server network unset [find address=192.168.19.0/24] next-server
```

## Booting a machine

1. Wired Ethernet on the home LAN. Wi-Fi cannot PXE boot.
2. Pick the network device once: the firmware boot menu (F12/F9/Esc at power-on), or
   on Windows hold **Shift** while clicking Restart, then Troubleshoot > Use a device >
   EFI Network (IPv4).
3. GRUB shows a menu. Pick **Join firefly as a k3s worker** within 10 seconds, or it
   falls through to the next boot device. Enrolled machines skip this (below).
4. Allow 2 to 5 minutes. The node appears as `ff-pxe-<last 6 hex of its MAC>`.

The machine needs at least 4 GiB of RAM: FCOS uses about 2 GiB with the rootfs in
memory, and container images and pod data also live in RAM.

### Auto-boot (enrolling a MAC)

Add the MAC to `AUTOBOOT_MACS` (space-separated) in
`kubernetes/apps/pxe-netboot/base/kustomization.yaml`. That machine then boots into
the worker after 3 seconds. On Windows the MAC is in `getmac /v /fo list` (no admin
needed).

## Scheduling onto PXE nodes

A PXE node vanishes whenever its machine boots back into its own OS, taking its pods
and everything they wrote with it. It registers with:

- labels `topology.sargeant.co/tier=pxe` and `topology.sargeant.co/ephemeral=true`
- taint `topology.sargeant.co/ephemeral=true:NoSchedule`

So nothing lands there unless it asks to. That includes Longhorn, so no volume replica
can end up in RAM, and ServiceLB, so traefik is never advertised on a laptop's IP.
DaemonSets that tolerate every taint (log shippers, node exporter) still run there.
Opt a stateless workload in with:

```yaml
nodeSelector:
  topology.sargeant.co/tier: pxe
tolerations:
  - key: topology.sargeant.co/ephemeral
    operator: Equal
    value: "true"
    effect: NoSchedule
```

The node deliberately carries neither `tier=on-prem` nor
`node-role.kubernetes.io/worker`: both are placement targets for apps whose state is a
`hostPath` on ff-vm1.

## Join token

PXE nodes use a kubeadm-style bootstrap token, not the cluster's node token. k3s
accepts bootstrap tokens for agents only, never servers, so a leaked token cannot add
a control-plane node.

- Token ID `ub1wdh` is in git. The secret half is OCI Vault `k3s-firefly-pxe-bootstrap-token`
  in `vault-prod`.
- ESO renders `kube-system/bootstrap-token-ub1wdh` (what the API server checks) and
  `networking/pxe-netboot-join-token` (`K10<CA hash>::ub1wdh.<secret>`, which the
  init container writes into Ignition).
- Ignition is served only to `LAN_CIDR`, from a memory-backed emptyDir.

**Revoke**: delete the vault entry. The bootstrap Secret goes with it and no new
node can join. Running agents keep working: they already hold client certificates.

**Rotate**: write a new 16-character `[a-z0-9]` value to the vault entry, then
`kubectl -n networking rollout restart deploy/pxe-netboot`. Each PXE node derives its
k3s node password from the token, so also `kubectl delete node ff-pxe-…` for every
PXE node, or k3s rejects them on their next boot as a duplicate hostname.

## Upgrading k3s

Bump `K3S_VERSION` and `K3S_SHA256` (the `k3s` line of the release's
`sha256sum-amd64.txt`) in the same change that upgrades the cluster. The SUC agent Plan
in [k3s version upgrade](k3s-version-upgrade.md) selects PXE nodes too, but its upgrade
only lasts until the machine reboots and fetches the pinned binary again.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Firmware says no boot file / PXE timeout | `/ip dhcp-server lease print detail where class-id~"PXEClient"` on ff-crs1; the matcher needs `address-pool` |
| Firmware fetches nothing over TFTP | `kubectl -n networking logs deploy/pxe-netboot -c tftp` (each file sent is logged) |
| Secure Boot violation after shim | Third-party UEFI CA disabled in the firmware, see above |
| GRUB menu but kernel load fails | `-c http` logs; GRUB falls back to TFTP by itself |
| Boots, never joins | `ssh core@<ip>` then `journalctl -u ff-pxe-identity -u k3s-agent` |
| `Node password rejected` in k3s-agent | Token rotated, or the same MAC suffix on two machines: `kubectl delete node ff-pxe-…` |
| Pod stuck in `Init` | `-c prepare` logs; it downloads ~1GB from Fedora and GitHub |
