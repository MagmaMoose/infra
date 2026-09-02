# k3s instances on the OCI ARM64 free tier, placed in the app subnet.
#
# Two modes:
#   k3s_url + k3s_token_secret_ocid set  -> install as agent joining the cluster
#   both empty                          -> install as standalone k3s server
#
# The join token is *not* baked into instance metadata. The agent-mode
# cloud-init script uses instance principal auth to fetch the token from
# OCI Vault at boot. Permission to read that specific secret is granted
# by the dynamic group + IAM policy in iam.tf.

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  # Per-server INSTALL_K3S_EXEC for agent mode: always "agent", plus an
  # optional --node-name (so the node registers as e.g. ff-oci1 rather than its
  # OS hostname) and any --node-label flags from var.servers[*].node_labels.
  #
  # node-role.kubernetes.io/* labels are deliberately NOT injectable here: the
  # kubelet may not self-register labels in the kubernetes.io/k8s.io namespaces
  # (NodeRestriction admission), so passing one would fail the join. Custom
  # labels (topology.sargeant.co/tier=native-cloud) are allowed; the worker role
  # label is applied post-join with kubectl (docs/reference/cluster-topology.md).
  k3s_agent_exec = {
    for k, s in var.servers : k =>
    "agent${s.node_name != "" ? " --node-name ${s.node_name}" : ""}${join("", [for l in s.node_labels : " --node-label ${l}"])}"
  }
}

# Hash of the inputs that *meaningfully* change cloud-init outcome —
# k3s_url, the secret OCID it should fetch (in agent mode), and the base
# image. Cosmetic script tweaks don't change the hash so don't recreate
# VMs.
#
# k3s_token_secret_ocid is folded out in server mode (k3s_url == "")
# because the OCID isn't read — pointing it at a different Vault secret
# shouldn't rebuild standalone-server VMs that ignore it.
#
# Escape hatch: set `cloud_init_rebuild_token` to any non-empty value to
# force a one-off replacement when you do edit the install script
# meaningfully (e.g. new cloud-init step). When unset (the default), the
# extra key is omitted entirely so the hash stays stable across applies
# and the default code path never surprises you with a fleet rebuild.
#
# k3s_version is DELIBERATELY NOT HASHED, and that is a safety property, not an
# oversight. Hashing it would mean the very first apply that introduces a pin
# replaces every VM this module manages — including ff-oci1/ff-oci2, which carry
# the postgres-oci CNPG instances. Terraform cannot roll a kubelet in place
# anyway: the VM is replaced wholesale, the Node object goes with it, and k3s
# reallocates a podCIDR, which invalidates any static route pinned to the old
# one. So a version change is applied deliberately, not as an apply side effect:
# either re-pin and set cloud_init_rebuild_token when the node is genuinely
# disposable, or reinstall in place on the node (uninstall + reinstall with
# INSTALL_K3S_VERSION, WITHOUT deleting the Node object, which preserves its
# podCIDR). Changing the pin alone affects only VMs created after it.
resource "terraform_data" "user_data_replace_trigger" {
  for_each = var.servers

  input = sha256(jsonencode(merge(
    {
      k3s_url               = var.k3s_url
      k3s_token_secret_ocid = var.k3s_url == "" ? "" : var.k3s_token_secret_ocid
      image                 = var.image_ocid
      # node_name / node_labels change the k3s registration identity, so a
      # rename (server-fd1 -> ff-oci1) or label change must replace the VM.
      node_name   = each.value.node_name
      node_labels = each.value.node_labels
    },
    var.cloud_init_rebuild_token == "" ? {} : { rebuild_token = var.cloud_init_rebuild_token }
  )))
}

resource "oci_core_instance" "this" {
  for_each = var.servers

  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  display_name        = each.value.node_name != "" ? each.value.node_name : "${var.environment}-server-${each.key}"
  shape               = var.shape
  fault_domain        = "FAULT-DOMAIN-${each.value.fault_domain + 1}"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = false
    nsg_ids          = [var.network_security_group_id]
    hostname_label   = each.value.node_name != "" ? each.value.node_name : "server-${each.key}"
    private_ip       = each.value.private_ip
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
    user_data = base64encode(<<-EOF
      #!/bin/bash
      exec > /var/log/k3s-install.log 2>&1
      # pipefail so a failing `oci` in the secret-fetch pipeline doesn't
      # get silently masked by a succeeding `base64 -d ""` returning 0.
      set -eo pipefail
      echo "k3s install starting at $(date)"

      if [ -n "${var.k3s_url}" ]; then
        echo "agent mode: will join ${var.k3s_url}"

        # Fetch the node-token from OCI Vault via instance principal.
        # oci-cli's `--auth instance_principal` flag uses the metadata
        # service to acquire a short-lived JWT from OCI's auth service
        # and signs subsequent API calls — no static credentials, no
        # token in instance metadata.
        #
        # pip on Ubuntu 22.04 doesn't recognise `--break-system-packages`
        # (introduced when PEP 668 marked external installs); only 23.04+
        # ships pip new enough. Detect the flag and add it only when
        # supported so the script works across image versions.
        #
        # oci-cli is pinned to var.oci_cli_version (default in variables.tf)
        # so node boots are reproducible; bumping the variable is the
        # explicit upgrade path. Empty string skips the pin (== "latest").
        echo "installing oci-cli (pin: ${var.oci_cli_version != "" ? var.oci_cli_version : "latest"})..."
        apt-get update -qq
        apt-get install -y -qq python3-pip
        PIP_ARGS="--quiet"
        if pip3 install --help 2>&1 | grep -q break-system-packages; then
          PIP_ARGS="$PIP_ARGS --break-system-packages"
        fi
        %{if var.oci_cli_version != ""~}
        pip3 install $PIP_ARGS "oci-cli==${var.oci_cli_version}"
        %{else~}
        pip3 install $PIP_ARGS oci-cli
        %{endif~}

        # Per-attempt stderr from BOTH `oci` and `base64 -d` is appended to
        # /var/log/oci-secret-fetch.log (the brace group + 2>> captures the
        # whole pipeline, and >> avoids truncating between retries so we can
        # see why all five attempts failed, not just the last one).
        #
        # The fetch loop relies on `set -o pipefail` (top of script): the
        # `oci | base64` pipeline exits non-zero when `oci` fails, so the
        # `if` condition is false and we retry. We additionally validate
        # the decoded value smells like a k3s node-token (starts with
        # `K10`, length >= 32) — defensive against the CLI ever returning
        # an unexpected stdout shape that survives base64-decoding to a
        # non-empty but invalid string.
        echo "fetching k3s token from OCI Vault (instance principal)..."
        for attempt in 1 2 3 4 5; do
          echo "=== attempt $attempt at $(date -u +%FT%TZ) ===" >> /var/log/oci-secret-fetch.log
          if K3S_TOKEN_VALUE=$({ oci secrets secret-bundle get \
              --secret-id ${var.k3s_token_secret_ocid} \
              --region ${var.region} \
              --auth instance_principal \
              --query 'data."secret-bundle-content".content' \
              --raw-output | base64 -d; } 2>>/var/log/oci-secret-fetch.log) \
             && [[ "$K3S_TOKEN_VALUE" == K10* ]] \
             && [ $${#K3S_TOKEN_VALUE} -ge 32 ]; then
            break
          fi
          K3S_TOKEN_VALUE=""
          echo "attempt $attempt failed (or token shape rejected); retrying in 10s..."
          sleep 10
        done

        if [ -z "$K3S_TOKEN_VALUE" ]; then
          echo "ERROR: couldn't fetch a well-formed k3s token from Vault after 5 tries. See /var/log/oci-secret-fetch.log."
          exit 1
        fi
        echo "token fetched (len=$${#K3S_TOKEN_VALUE})"

        curl -sfL https://get.k3s.io | \
          ${var.k3s_version == "" ? "" : "INSTALL_K3S_VERSION=\"${var.k3s_version}\" \\\n          "}INSTALL_K3S_EXEC="${local.k3s_agent_exec[each.key]}" \
          K3S_URL="${var.k3s_url}" \
          K3S_TOKEN="$K3S_TOKEN_VALUE" \
          sh -

        echo "k3s-agent service installed at $(date); will retry connection until ${var.k3s_url} is reachable"
      else
        echo "server mode: standalone k3s control plane"
        curl -sfL https://get.k3s.io | ${var.k3s_version == "" ? "" : "INSTALL_K3S_VERSION=\"${var.k3s_version}\" "}sh -
        mkdir -p /home/ubuntu/.kube
        cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
        chown -R ubuntu:ubuntu /home/ubuntu/.kube
        chmod 600 /home/ubuntu/.kube/config
        echo "k3s server installed at $(date)"
      fi
    EOF
    )
  }

  freeform_tags = {
    "Environment" = var.environment
    "Role"        = "k3s-${var.k3s_url == "" ? "server" : "agent"}"
    "ManagedBy"   = "Terraform"
  }

  lifecycle {
    # source_details: don't fight image version drift if the OCI image gets republished.
    # metadata.user_data: cosmetic script tweaks shouldn't replace VMs.
    # Meaningful changes (k3s_url / k3s_token_secret_ocid / image) propagate
    # via replace_triggered_by on the user_data_replace_trigger hash.
    ignore_changes = [
      source_details[0].source_id,
      metadata["user_data"]
    ]

    replace_triggered_by = [
      terraform_data.user_data_replace_trigger[each.key],
    ]

    precondition {
      condition     = (var.k3s_url == "" && var.k3s_token_secret_ocid == "") || (var.k3s_url != "" && var.k3s_token_secret_ocid != "")
      error_message = "k3s_url and k3s_token_secret_ocid must be set together (agent mode) or both empty (standalone server mode). Setting one without the other is silently broken."
    }
  }

  depends_on = [
    # Make sure the dynamic group + IAM policy exist before the VM boots and
    # tries to fetch the secret. IAM eventual consistency means a freshly
    # created instance might still fail the first fetch — that's why the
    # cloud-init has a 5-attempt retry with backoff.
    oci_identity_policy.k3s_servers_vault_read,
  ]
}
