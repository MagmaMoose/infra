#!/bin/bash
# Gives a RAM-only PXE node the same identity on every boot, before k3s starts.
#  - hostname ff-pxe-<last 6 hex digits of the boot NIC's MAC>, so the same Node
#    object comes back instead of a new one per boot.
#  - /etc/rancher/node/password derived from the join token and the MAC. k3s
#    rejects a returning node whose password differs from the one it first
#    registered with, and a RAM-only node would otherwise generate a new random
#    one each boot. Rotating the join token therefore means deleting these Nodes.
set -euo pipefail

dev=""
for _ in $(seq 1 60); do
  dev=$(ip -o -4 route show default | awk '{ print $5; exit }')
  [ -n "$dev" ] && break
  sleep 2
done
[ -n "$dev" ] || { echo "no default route after 120s" >&2; exit 1; }

mac=$(cat "/sys/class/net/$dev/address")
name="ff-pxe-$(printf '%s' "$mac" | tr -d ':' | cut -c7-12)"
hostnamectl set-hostname "$name"

token=$(sed -n 's/^token: *//p' /etc/rancher/k3s/config.yaml)
install -d -m 0700 /etc/rancher/node
umask 077
printf '%s/%s' "$token" "$mac" | sha256sum | cut -c1-32 > /etc/rancher/node/password
echo "node identity: $name ($dev $mac)"
