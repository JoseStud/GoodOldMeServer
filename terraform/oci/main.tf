terraform {
  required_providers {
    oci = { source = "oracle/oci", version = "~> 5.0" }
  }
}

# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────

variable "oci_compartment_ocid" {
  description = "OCI compartment OCID where all resources will be created"
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.compartment\\.oc1\\..*$", var.oci_compartment_ocid))
    error_message = "Must be a valid OCI compartment OCID (ocid1.compartment.oc1...)."
  }
}

variable "ssh_ca_public_key" {
  description = "SSH CA public key injected into instances via cloud-init for certificate-based auth"
  type        = string
  sensitive   = true
}

variable "oci_image_ocid" {
  description = "OCI image OCID for the worker instances (Ubuntu aarch64)"
  type        = string
  # No default — must be explicitly provided to avoid stale/placeholder values

  validation {
    condition     = can(regex("^ocid1\\.image\\.oc1\\..*$", var.oci_image_ocid))
    error_message = "Must be a valid OCI image OCID (ocid1.image.oc1...)."
  }
}

variable "ssh_enabled" {
  description = "Whether SSH ingress should be managed for OCI worker instances"
  type        = bool
  default     = true
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to SSH into instances (restrict to deterministic runner egress)"
  type        = list(string)

  validation {
    condition = (
      alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrhost(cidr, 0)) && !strcontains(cidr, ":")]) &&
      (!var.ssh_enabled || length(var.ssh_allowed_cidrs) > 0)
    )
    error_message = "ssh_allowed_cidrs must contain valid IPv4 CIDRs and must be non-empty when ssh_enabled=true."
  }
}

locals {
  common_tags = {
    project    = "goodoldme"
    managed_by = "terraform"
  }
}

# ──────────────────────────────────────────────
# Networking — VCN, Internet Gateway, Subnet
# ──────────────────────────────────────────────

resource "oci_core_vcn" "main_vcn" {
  compartment_id = var.oci_compartment_ocid
  display_name   = "production-vcn"
  cidr_block     = "10.0.0.0/16"
  freeform_tags  = local.common_tags
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "production-igw"
  enabled        = true
  freeform_tags  = local.common_tags
}

resource "oci_core_default_route_table" "default_rt" {
  manage_default_resource_id = oci_core_vcn.main_vcn.default_route_table_id
  display_name               = "production-default-rt"
  freeform_tags              = local.common_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_subnet" "dmz_subnet" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main_vcn.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "dmz-subnet"
  route_table_id = oci_core_default_route_table.default_rt.id
  freeform_tags  = local.common_tags
}

# ──────────────────────────────────────────────
# Compute — Ampere A1.Flex Workers
# ──────────────────────────────────────────────

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_compartment_ocid
}

resource "oci_core_instance" "app_worker" {
  count               = 2
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index % length(data.oci_identity_availability_domains.ads.availability_domains)].name
  compartment_id      = var.oci_compartment_ocid
  shape               = "VM.Standard.A1.Flex"
  display_name        = "app-worker-${count.index + 1}"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.dmz_subnet.id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.gateway_nsg.id]
  }

  metadata = {
    user_data = base64encode(<<-EOF
      #cloud-config
      runcmd:
        - echo '${var.ssh_ca_public_key}' > /etc/ssh/trusted-user-ca-keys.pem
        - echo 'TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem' >> /etc/ssh/sshd_config
        - systemctl restart sshd
    EOF
    )
  }

  freeform_tags = local.common_tags

  source_details {
    source_type             = "image"
    source_id               = var.oci_image_ocid
    boot_volume_size_in_gbs = 50
  }
}

# ──────────────────────────────────────────────
# Network Security Group + Rules
# ──────────────────────────────────────────────

resource "oci_core_network_security_group" "gateway_nsg" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "gateway-nsg"
  freeform_tags  = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "gateway_http" {
  network_security_group_id = oci_core_network_security_group.gateway_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      max = 80
      min = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "gateway_https" {
  network_security_group_id = oci_core_network_security_group.gateway_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      max = 443
      min = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ssh" {
  for_each                  = toset(nonsensitive(var.ssh_enabled) ? nonsensitive(var.ssh_allowed_cidrs) : [])
  network_security_group_id = oci_core_network_security_group.gateway_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "SSH access — restricted to approved runner CIDRs"
  tcp_options {
    destination_port_range {
      max = 22
      min = 22
    }
  }
}

# ──────────────────────────────────────────────
# Block Storage + Backups
# ──────────────────────────────────────────────

resource "oci_core_volume" "worker_volume" {
  count               = 2
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index % length(data.oci_identity_availability_domains.ads.availability_domains)].name
  compartment_id      = var.oci_compartment_ocid
  display_name        = "worker-volume-${count.index}"
  size_in_gbs         = 50
  freeform_tags       = local.common_tags
}

data "oci_core_volume_backup_policies" "silver" {
  filter {
    name   = "display_name"
    values = ["silver"]
  }
}

resource "oci_core_volume_backup_policy_assignment" "worker_volume_backup" {
  count     = 2
  asset_id  = oci_core_volume.worker_volume[count.index].id
  policy_id = data.oci_core_volume_backup_policies.silver.volume_backup_policies[0].id
}

resource "oci_core_volume_attachment" "worker_volume_attachment" {
  count           = 2
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.app_worker[count.index].id
  volume_id       = oci_core_volume.worker_volume[count.index].id
}

output "public_worker_ips" {
  description = "List of public IPv4 addresses for both OCI worker instances"
  value       = oci_core_instance.app_worker[*].public_ip
}
