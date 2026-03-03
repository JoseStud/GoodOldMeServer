terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci       = { source = "oracle/oci", version = "~> 5.0" }
    google    = { source = "hashicorp/google", version = "~> 5.0" }
    infisical = { source = "Infisical/infisical", version = ">= 0.8.0" }
  }

  # TODO: Configure a remote backend for state persistence and locking.
  # Options: OCI Object Storage (S3-compatible), GCS, or Terraform Cloud.
  # Example:
  # backend "s3" {
  #   bucket   = "goodoldme-tf-state"
  #   key      = "terraform.tfstate"
  #   region   = "us-ashburn-1"
  #   endpoint = "https://<namespace>.compat.objectstorage.<region>.oraclecloud.com"
  #   ...
  # }
}

# ──────────────────────────────────────────────────
# Providers
# ──────────────────────────────────────────────────

provider "infisical" {
  host = "https://app.infisical.com"
}

provider "oci" {
  tenancy_ocid = local.secrets.oci_tenancy_ocid
  user_ocid    = local.secrets.oci_user_ocid
  fingerprint  = local.secrets.oci_fingerprint
  private_key  = local.secrets.oci_private_key
  region       = var.oci_region
}

provider "google" {
  credentials = local.secrets.gcp_service_account_key
  project     = jsondecode(local.secrets.gcp_service_account_key).project_id
  region      = "us-central1"
}

# ──────────────────────────────────────────────────
# Secrets from Infisical
# ──────────────────────────────────────────────────

data "infisical_secrets" "infra" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/infrastructure"
}

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

# Map Infisical secret keys to local names for clarity and typo safety
locals {
  secrets = {
    # /infrastructure
    base_domain = data.infisical_secrets.infra.secrets["BASE_DOMAIN"].value
    tz          = data.infisical_secrets.infra.secrets["TZ"].value

    # /security
    ssh_ca_public_key = data.infisical_secrets.security.secrets["SSH_CA_PUBLIC_KEY"].value

    # /cloud-provider/oci
    oci_tenancy_ocid    = data.infisical_secrets.oci.secrets["OCI_TENANCY_OCID"].value
    oci_user_ocid       = data.infisical_secrets.oci.secrets["OCI_USER_OCID"].value
    oci_fingerprint     = data.infisical_secrets.oci.secrets["OCI_FINGERPRINT"].value
    oci_private_key     = data.infisical_secrets.oci.secrets["OCI_PRIVATE_KEY"].value
    oci_compartment_id  = data.infisical_secrets.oci.secrets["OCI_COMPARTMENT_OCID"].value
    oci_image_ocid      = data.infisical_secrets.oci.secrets["OCI_IMAGE_OCID"].value

    # /cloud-provider/gcp
    gcp_service_account_key = data.infisical_secrets.gcp.secrets["GCP_SERVICE_ACCOUNT_KEY"].value
  }
}

# ──────────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────────

variable "infisical_project_id" {
  description = "Infisical workspace/project ID for secret retrieval"
  type        = string
}

variable "oci_region" {
  description = "OCI region for the provider"
  type        = string
  default     = "us-ashburn-1"
}

# ──────────────────────────────────────────────────
# Modules
# ──────────────────────────────────────────────────

module "oci" {
  source               = "./oci"
  oci_compartment_ocid = local.secrets.oci_compartment_id
  ssh_ca_public_key    = local.secrets.ssh_ca_public_key
  oci_image_ocid       = local.secrets.oci_image_ocid
}

module "gcp" {
  source      = "./gcp"
  gcp_project = jsondecode(local.secrets.gcp_service_account_key).project_id
}

# ──────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────

output "oci_public_ips" {
  description = "Public IPv4 addresses of the OCI worker instances"
  value       = module.oci.public_worker_ips
}

output "gcp_witness_ipv6" {
  description = "External IPv6 address of the GCP Swarm witness instance"
  value       = module.gcp.witness_ipv6
}
