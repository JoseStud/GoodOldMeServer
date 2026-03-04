terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci       = { source = "oracle/oci", version = "~> 5.0" }
    google    = { source = "hashicorp/google", version = "~> 5.0" }
    infisical = { source = "Infisical/infisical", version = ">= 0.8.0" }
  }
}

# Providers
provider "infisical" {
  host = "https://app.infisical.com"
}

provider "oci" {
  auth   = "SecurityToken"
  region = var.oci_region
}

provider "google" {
  project = local.secrets.gcp_project_id
  region  = "us-central1"
}

# Secrets from Infisical
data "infisical_secrets" "security" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/security"
}

data "infisical_secrets" "oci" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/cloud-provider/oci"
}

data "infisical_secrets" "gcp" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/cloud-provider/gcp"
}

locals {
  secrets = {
    ssh_ca_public_key  = data.infisical_secrets.security.secrets["SSH_CA_PUBLIC_KEY"].value
    oci_compartment_id = data.infisical_secrets.oci.secrets["OCI_COMPARTMENT_OCID"].value
    oci_image_ocid     = data.infisical_secrets.oci.secrets["OCI_IMAGE_OCID"].value
    gcp_project_id     = data.infisical_secrets.gcp.secrets["GCP_PROJECT_ID"].value
  }
}

# Variables
variable "infisical_project_id" {
  description = "Infisical workspace/project ID for secret retrieval"
  type        = string
}

variable "oci_region" {
  description = "OCI region for the provider"
  type        = string
  default     = "us-ashburn-1"
}

variable "oci_ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH into OCI worker nodes"
  type        = string
}

variable "gcp_ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH into the GCP witness node"
  type        = list(string)
}

# Modules
module "oci" {
  source               = "../oci"
  oci_compartment_ocid = local.secrets.oci_compartment_id
  ssh_ca_public_key    = local.secrets.ssh_ca_public_key
  oci_image_ocid       = local.secrets.oci_image_ocid
  ssh_allowed_cidr     = var.oci_ssh_allowed_cidr
}

module "gcp" {
  source            = "../gcp"
  gcp_project       = local.secrets.gcp_project_id
  ssh_allowed_cidrs = var.gcp_ssh_allowed_cidrs
}

# Outputs
output "oci_public_ips" {
  description = "Public IPv4 addresses of the OCI worker instances"
  value       = module.oci.public_worker_ips
}

output "gcp_witness_ipv6" {
  description = "External IPv6 address of the GCP Swarm witness instance"
  value       = module.gcp.witness_ipv6
}
