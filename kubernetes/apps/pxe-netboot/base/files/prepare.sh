#!/bin/sh
# Init container for pxe-netboot. Fills two emptyDirs:
#   /srv/boot       served over TFTP and HTTP: shim, GRUB, grub.cfg, the Fedora
#                   CoreOS live kernel/initramfs/rootfs and the k3s binary
#   /srv/ignition   served over HTTP only, LAN-restricted: the Ignition config,
#                   which carries the k3s join token
# Every download is verified (FCOS by coreos-installer's GPG check, shim/GRUB by
# rpmkeys, k3s by sha256) before anything is published.
set -eu

: "${HOST_IP:?}" "${HTTP_PORT:?}" "${LAN_CIDR:?}" "${FCOS_STREAM:?}"
: "${K3S_VERSION:?}" "${K3S_SHA256:?}" "${K3S_SERVER:?}" "${SSH_KEYS_GITHUB_USER:?}"
AUTOBOOT_MACS="${AUTOBOOT_MACS:-}"

BOOT=/srv/boot
IGN=/srv/ignition
TPL=/pxe
work=$(mktemp -d)
mkdir -p "$BOOT/fcos" "$BOOT/k3s" "$IGN" "$work/fcos" "$work/rpm"

token=$(cat /run/pxe-join/token)
case "$token" in
  K10*::??????.????????????????) ;;
  *) echo "join token is not K10<hash>::<id>.<secret>" >&2; exit 1 ;;
esac

echo "== Fedora CoreOS ($FCOS_STREAM) live PXE images"
# --architecture is required: it defaults to the host's, and this runs on an arm64 Pi.
coreos-installer download --stream "$FCOS_STREAM" --architecture x86_64 \
  --platform metal --format pxe --directory "$work/fcos" --fetch-retries 3
for part in kernel initramfs rootfs; do
  src=$(find "$work/fcos" -name "*-live-$part*" ! -name '*.sig' | head -n1)
  [ -n "$src" ] || { echo "no live $part in the download" >&2; exit 1; }
  case "$part" in
    kernel) mv "$src" "$BOOT/fcos/kernel"; basename "$src" > "$BOOT/fcos/RELEASE" ;;
    *) mv "$src" "$BOOT/fcos/$part.img" ;;
  esac
done
cat "$BOOT/fcos/RELEASE"

echo "== shim + GRUB, signed for UEFI Secure Boot"
# Fedora's shim is signed by Microsoft's UEFI CA and only boots a Fedora-signed
# GRUB, which only boots a Fedora-signed kernel. FCOS kernels are Fedora-signed.
cd "$work/rpm"
dnf5 -q download --forcearch=x86_64 --arch=x86_64 shim-x64 grub2-efi-x64
rpmkeys --import "/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$(rpm -E %fedora)-primary"
for p in ./*.rpm; do
  rpmkeys --checksig "$p" | grep -q ': digests signatures OK$' || {
    echo "signature check failed: $p" >&2; exit 1; }
  rpm2archive - < "$p" | tar -xz
done
cd /
# GRUB reads grub.cfg from the directory it was loaded from, so everything sits
# at the TFTP root. mmx64.efi is MokManager, which shim loads only if it needs to.
for f in shimx64.efi mmx64.efi grubx64.efi; do
  src=$(find "$work/rpm" -path "*/EFI/fedora/$f" | head -n1)
  [ -n "$src" ] || { echo "$f not found in the RPMs" >&2; exit 1; }
  cp "$src" "$BOOT/$f"
done

echo "== k3s $K3S_VERSION"
k3s_url="https://github.com/k3s-io/k3s/releases/download/$(printf %s "$K3S_VERSION" | sed 's/+/%2B/g')/k3s"
curl -fsSL --retry 3 -o "$BOOT/k3s/k3s" "$k3s_url"
echo "$K3S_SHA256  $BOOT/k3s/k3s" | sha256sum -c -

echo "== SSH keys for core (github.com/$SSH_KEYS_GITHUB_USER)"
curl -fsSL --retry 3 -o "$work/authorized_keys" "https://github.com/$SSH_KEYS_GITHUB_USER.keys"
grep -qE '^(ssh-|ecdsa-sha2-|sk-)' "$work/authorized_keys" || { echo "no SSH keys published" >&2; exit 1; }

echo "== grub.cfg"
: > "$work/autoboot"
for mac in $AUTOBOOT_MACS; do
  mac=$(printf %s "$mac" | tr 'A-F-' 'a-f:')
  # shellcheck disable=SC2016 # $net_default_mac is GRUB's variable, not ours
  printf 'if [ "$net_default_mac" = "%s" ]; then set default=fcos; set timeout=3; fi\n' "$mac" >> "$work/autoboot"
done
sed -e "s|@@HOST_IP@@|$HOST_IP|g" -e "s|@@HTTP_PORT@@|$HTTP_PORT|g" "$TPL/grub.cfg.tmpl" |
  awk -v f="$work/autoboot" '$0 == "@@AUTOBOOT@@" { while ((getline l < f) > 0) print l; next } { print }' \
  > "$BOOT/grub.cfg"

echo "== nginx.conf"
sed -e "s|@@HTTP_PORT@@|$HTTP_PORT|g" -e "s|@@LAN_CIDR@@|$LAN_CIDR|g" \
  "$TPL/nginx.conf.tmpl" > /srv/nginx/default.conf

echo "== Ignition config"
sed -e "s|@@K3S_SERVER@@|$K3S_SERVER|g" -e "s|@@TOKEN@@|$token|g" \
  "$TPL/k3s-config.yaml.tmpl" > "$work/k3s-config.yaml"
data() { printf 'data:;base64,%s' "$(base64 -w0 "$1")"; }
k3s_source="http://$HOST_IP:$HTTP_PORT/k3s/k3s"  # DevSkim: ignore DS137138 - LAN-only PXE server; integrity guaranteed by sha256 in the Ignition verification field
# Modes are decimal: 493 = 0755, 420 = 0644, 384 = 0600, 448 = 0700.
cat > "$IGN/worker.ign" <<EOF
{
  "ignition": { "version": "3.4.0" },
  "storage": {
    "directories": [
      { "path": "/home/core/.ssh", "mode": 448, "user": { "name": "core" }, "group": { "name": "core" } },
      { "path": "/home/core/.ssh/authorized_keys.d", "mode": 448, "user": { "name": "core" }, "group": { "name": "core" } }
    ],
    "files": [
      { "path": "/usr/local/bin/k3s", "mode": 493,
        "contents": { "source": "$k3s_source", "verification": { "hash": "sha256-$K3S_SHA256" } } },
      { "path": "/etc/rancher/k3s/config.yaml", "mode": 384, "contents": { "source": "$(data "$work/k3s-config.yaml")" } },
      { "path": "/usr/local/bin/ff-pxe-identity", "mode": 493, "contents": { "source": "$(data "$TPL/ff-pxe-identity.sh")" } },
      { "path": "/etc/systemd/system/ff-pxe-identity.service", "mode": 420, "contents": { "source": "$(data "$TPL/ff-pxe-identity.service")" } },
      { "path": "/etc/systemd/system/k3s-agent.service", "mode": 420, "contents": { "source": "$(data "$TPL/k3s-agent.service")" } },
      { "path": "/etc/systemd/logind.conf.d/50-ff-pxe.conf", "mode": 420, "contents": { "source": "$(data "$TPL/logind.conf")" } },
      { "path": "/etc/sysctl.d/90-ff-pxe.conf", "mode": 420, "contents": { "source": "$(data "$TPL/sysctl.conf")" } },
      { "path": "/home/core/.ssh/authorized_keys.d/github", "mode": 384, "user": { "name": "core" }, "group": { "name": "core" },
        "contents": { "source": "$(data "$work/authorized_keys")" } }
    ]
  },
  "systemd": {
    "units": [
      { "name": "ff-pxe-identity.service", "enabled": true },
      { "name": "k3s-agent.service", "enabled": true },
      { "name": "zincati.service", "mask": true },
      { "name": "sleep.target", "mask": true },
      { "name": "suspend.target", "mask": true },
      { "name": "hibernate.target", "mask": true },
      { "name": "hybrid-sleep.target", "mask": true }
    ]
  }
}
EOF

# dnsmasq and nginx run as unprivileged users and need read access.
chmod -R a+rX "$BOOT" "$IGN" /srv/nginx
rm -rf "$work"
echo "== ready: next-server $HOST_IP, boot file shimx64.efi, HTTP :$HTTP_PORT"
