variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., prod, dev)"
  type        = string
}

variable "shape" {
  description = "Shape of the instance"
  type        = string
  default     = "VM.Standard.A1.Flex" # Free tier ARM instance
}

variable "image_ocid" {
  description = "OCID of the image to use for the instance"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
}

variable "subnet_id" {
  description = "ID of the app subnet"
  type        = string
}

variable "network_security_group_id" {
  description = "ID of the Network Security Group"
  type        = string
}

variable "ocpus" {
  description = "Number of OCPUs for the instance"
  type        = number
  default     = 2 # 2 OCPUs per server (total 4 for 2 servers = free tier limit)
}

variable "memory_in_gbs" {
  description = "Amount of memory in GBs for the instance"
  type        = number
  default     = 12 # 12GB per server (total 24GB for 2 servers = free tier limit)
}

variable "vcn_id" {
  description = "ID of the VCN"
  type        = string
}

variable "servers" {
  description = "Map of servers to create"
  type = map(object({
    fault_domain = number
    private_ip   = optional(string)
    # k3s node name to register as (e.g. "ff-oci1"). Empty => the node
    # registers under its OS hostname (server-<key>). Drives display_name +
    # hostname_label too so the OCI console matches the cluster.
    node_name = optional(string, "")
    # Extra k3s --node-label flags applied at agent registration, each as
    # "key=value" (value may be empty). NOTE: kubelet self-registration cannot
    # set labels in the kubernetes.io / k8s.io namespaces (NodeRestriction), so
    # only custom-domain labels belong here (e.g. topology.sargeant.co/tier=...).
    # Role labels like node-role.kubernetes.io/worker must be applied post-join
    # with kubectl — see docs/reference/cluster-topology.md.
    node_labels = optional(list(string), [])
  }))
  default = {
    "fd1" = { fault_domain = 0 }
    "fd2" = { fault_domain = 1 }
  }
}

variable "k3s_version" {
  description = "Exact k3s version to install (e.g. v1.33.4+k3s1). Empty installs whatever the `stable` channel serves ON THE DAY THE VM BOOTS, which is how ff-oci3/ff-oci4 landed on v1.36.4+k3s1 against a v1.33.4 control plane on 2026-08-31 — three minors AHEAD, which the Kubernetes skew policy does not allow in that direction (a kubelet may trail the API server, never lead it). Always pin."
  type        = string
  default     = ""

  validation {
    condition     = var.k3s_version == "" || can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version must look like v1.33.4+k3s1 (or be empty to track the stable channel)."
  }
}

variable "k3s_url" {
  description = "URL of the existing k3s server to join as an agent (e.g. https://192.168.19.10:6443). Empty disables agent mode (server-mode install instead). Must be set together with k3s_token_secret_ocid."
  type        = string
  default     = ""

  validation {
    condition     = var.k3s_url == "" || can(regex("^https?://", var.k3s_url))
    error_message = "k3s_url must start with http:// or https:// (or be empty for server mode)."
  }
}

variable "k3s_token_secret_ocid" {
  description = "OCID of the OCI Vault secret holding the k3s node-token. The instance fetches this at boot via instance principal — see the dynamic group + IAM policy in this module. Empty disables agent mode (same effect as k3s_url == \"\"). Must be set together with k3s_url."
  type        = string
  default     = ""

  validation {
    condition     = var.k3s_token_secret_ocid == "" || can(regex("^ocid1\\.vaultsecret\\.", var.k3s_token_secret_ocid))
    error_message = "k3s_token_secret_ocid must be an OCI Vault Secret OCID (starting with ocid1.vaultsecret.) or empty."
  }
}

variable "cloud_init_rebuild_token" {
  description = "Opt-in escape hatch for forcing a VM rebuild after a meaningful cloud-init edit. Set to any non-empty value (e.g. \"2026-05-19\" or \"1\") to fold it into the user_data hash so existing VMs replace. Leave empty (the default) and routine applies won't replace VMs purely because the install script's wording changed."
  type        = string
  default     = ""
}

variable "oci_cli_version" {
  description = "PyPI version of oci-cli that the cloud-init script pins (so node boots are reproducible — a future oci-cli release that changes the secret-bundle CLI shape can't silently break new VMs). Set to empty string to skip the pin and install latest (not recommended)."
  type        = string
  default     = "3.73.1"

  validation {
    condition     = var.oci_cli_version == "" || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.oci_cli_version))
    error_message = "oci_cli_version must be a PyPI version (e.g. \"3.73.1\") or empty to install latest."
  }
}
