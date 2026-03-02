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

resource "oci_core_instance" "app_server" {
  count               = 2
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.oci_compartment_ocid
  shape               = "VM.Standard.A1.Flex" # Good for always free
  display_name        = "app-server-${count.index}"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.dmz_subnet.id
    assign_public_ip = true
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
  
  # Note: A real implementation requires a source_details block (image_id). 
  # Using a placeholder variable for valid syntax
  source_details {
    source_type = "image"
    source_id   = var.oci_image_ocid
  }
}

variable "oci_image_ocid" { default = "ocid1.image.oc1..." }

output "public_ips" {
  value = oci_core_instance.app_server[*].public_ip
}
