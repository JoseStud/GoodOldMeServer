terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci       = { source = "oracle/oci", version = "~> 5.0" }
    google    = { source = "hashicorp/google", version = "~> 5.0" }
    infisical = { source = "Infisical/infisical", version = ">= 0.8.0" }
    portainer = { source = "portainer/portainer", version = "~> 1.0" }
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
  # Authenticate via OCI Workload Identity Authentication (OIDC)
  auth = "SecurityToken"

  # Optional but recommended based on deployment CI
  region = var.oci_region
}

provider "google" {
  # Authenticate via GCP Workload Identity Federation (WIF)
  # Requires `GOOGLE_CREDENTIALS` or `GOOGLE_APPLICATION_CREDENTIALS` in the environment
  project = local.secrets.gcp_project_id
  region  = "us-central1"
}

provider "portainer" {
  # Authenticate via API key stored in Infisical /management
  endpoint = local.secrets.portainer_url
  api_key  = local.secrets.portainer_api_key
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

data "infisical_secrets" "management" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/management"
}

# Map Infisical secret keys to local names for clarity and typo safety
locals {
  secrets = {
    # /infrastructure
    base_domain = data.infisical_secrets.infra.secrets["BASE_DOMAIN"].value

    # /security
    ssh_ca_public_key = data.infisical_secrets.security.secrets["SSH_CA_PUBLIC_KEY"].value

    # /cloud-provider/oci
    oci_compartment_id  = data.infisical_secrets.oci.secrets["OCI_COMPARTMENT_OCID"].value
    oci_image_ocid      = data.infisical_secrets.oci.secrets["OCI_IMAGE_OCID"].value

    # /cloud-provider/gcp
    gcp_project_id      = data.infisical_secrets.gcp.secrets["GCP_PROJECT_ID"].value

    # /management (Portainer)
    portainer_url     = data.infisical_secrets.management.secrets["PORTAINER_URL"].value
    portainer_api_key = data.infisical_secrets.management.secrets["PORTAINER_API_KEY"].value
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

variable "portainer_endpoint_id" {
  description = "Portainer environment (endpoint) ID for the Swarm cluster"
  type        = number
  default     = 1
}

variable "repository_url" {
  description = "Git repository URL containing the stack compose files"
  type        = string
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
  gcp_project = local.secrets.gcp_project_id
}

module "portainer" {
  source               = "./portainer"
  endpoint_id          = var.portainer_endpoint_id
  repository_url       = var.repository_url
  infisical_project_id = var.infisical_project_id
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

output "portainer_webhook_urls" {
  description = "Map of stack names to their Portainer GitOps webhook URLs"
  value       = module.portainer.webhook_urls
  sensitive   = true
}
