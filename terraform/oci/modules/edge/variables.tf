variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment"
  type        = string
}

variable "vcn_id" {
  description = "OCID of the VCN"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., prod, dev)"
  type        = string
}

variable "shape" {
  description = "Shape of the instance"
  type        = string
  default     = "VM.Standard.E2.1.Micro" # Free tier x86 instance
}

variable "image_ocid" {
  description = "OCID of the image to use for the instance"
  type        = string
  # Default to Oracle Linux 8 for x86
  default = "ocid1.image.oc1.eu-amsterdam-1.aaaaaaaawxrjyvekcjkpi3zo6x3fphepbrjrbvr2dkcdxwir7xdwpv2yfvqa"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet"
  type        = string
}

variable "network_security_group_id" {
  description = "ID of the Network Security Group"
  type        = string
}

variable "fault_domains" {
  description = "Map of fault domains to create instances in"
  type = map(object({
    fault_domain = number
    private_ip   = optional(string)
    # OCI display_name for the instance (e.g. "ff-chr3"), so the console matches
    # the ff-<type><n> naming used everywhere else. Empty (the default) keeps the
    # historical "<environment>-mikrotik-chr-<key>" name, which is what the
    # firefly edge leaf relies on. Mirrors `node_name` in modules/server.
    #
    # Not wired to create_vnic_details.hostname_label on purpose: that attribute
    # is absent today, so setting it would be a live UpdateVnic on the existing
    # CHRs, and RouterOS ignores OCI-provided DNS anyway.
    node_name = optional(string, "")
  }))
  default = {
    "fd1" = { fault_domain = 0 }
  }
}

variable "use_reserved_public_ips" {
  description = "When true, the edge instances' VNICs use OCI Reserved public IPs instead of ephemeral ones — keeps the IP stable across instance recreates. Default false matches historical behaviour. Flipping false → true on existing infra is a deliberate one-off cutover: the ephemeral IP is released and a new reserved IP is allocated, so the public IP value WILL change at that apply (and DNS records sourced from this module's outputs will follow). OCI Always Free allows 2 reserved public IPs per tenancy at no cost, which is exactly the edge fleet size."
  type        = bool
  default     = false
}
