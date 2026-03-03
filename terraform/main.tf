terraform {
  required_providers {
    oci       = { source = "oracle/oci", version = "~> 5.0" }
    google    = { source = "hashicorp/google", version = "~> 5.0" }
    infisical = { source = "Infisical/infisical", version = ">= 0.8.0" }
  }
}

provider "infisical" {
  host = "https://app.infisical.com"
}

data "infisical_secrets" "infra" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/Infrastructure"
}

variable "infisical_project_id" {
  type = string
}

module "oci" {
  source               = "./oci"
  oci_compartment_ocid = data.infisical_secrets.infra.secrets["OCI_COMPARTMENT_ID"].value
  ssh_ca_public_key    = data.infisical_secrets.infra.secrets["INSTANCE_SSH_PUBKEY"].value # For ephemeral SSH, make sure this holds the SSH CA Public Key
}

module "gcp" {
  source      = "./gcp"
  gcp_project = data.infisical_secrets.infra.secrets["GCP_PROJECT_ID"].value
}

output "oci_public_ips" {
  value = module.oci.public_ips
}

output "gcp_witness_public_ip" {
  value = module.gcp.witness_public_ip
}
