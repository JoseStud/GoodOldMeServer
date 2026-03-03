terraform {
  required_providers {
    oci = { source = "oracle/oci", version = "~> 5.0" }
  }
}

variable "oci_compartment_ocid" {}

resource "oci_core_vcn" "main_vcn" {
  compartment_id = var.oci_compartment_ocid
  display_name   = "production-vcn"
  cidr_block     = "10.0.0.0/16"
}

resource "oci_core_subnet" "dmz_subnet" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main_vcn.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "dmz-subnet"
  route_table_id = oci_core_vcn.main_vcn.default_route_table_id
}

# Assuming an Ampere A1 (Always Free) or similar Data Source for AD.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_compartment_ocid
}

variable "ssh_ca_public_key" {}

resource "oci_core_instance" "app_worker" {
  count               = 2
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
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

  source_details {
    source_type             = "image"
    source_id               = var.oci_image_ocid
    boot_volume_size_in_gbs = 50
  }
}

variable "oci_image_ocid" { default = "ocid1.image.oc1..." }

resource "oci_core_network_security_group" "gateway_nsg" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.main_vcn.id
  display_name   = "gateway-nsg"
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



resource "oci_core_volume" "worker_volume" {
  count               = 2
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.oci_compartment_ocid
  display_name        = "worker-volume-${count.index}"
  size_in_gbs         = 50
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
  value = oci_core_instance.app_worker[*].public_ip
}
