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
  region       = var.oci_region
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  fingerprint  = var.oci_fingerprint
  private_key  = var.oci_private_key
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

data "infisical_secrets" "infrastructure" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/infrastructure"
}

locals {
  secrets = {
    ssh_ca_public_key  = data.infisical_secrets.security.secrets["SSH_CA_PUBLIC_KEY"].value
    oci_compartment_id = data.infisical_secrets.oci.secrets["OCI_COMPARTMENT_OCID"].value
    oci_image_ocid     = data.infisical_secrets.oci.secrets["OCI_IMAGE_OCID"].value
    gcp_project_id     = data.infisical_secrets.gcp.secrets["GCP_PROJECT_ID"].value
    tailscale_auth_key = data.infisical_secrets.infrastructure.secrets["TAILSCALE_AUTH_KEY"].value
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

variable "oci_tenancy_ocid" {
  description = "OCI tenancy OCID for API key authentication"
  type        = string
  sensitive   = true
}

variable "oci_user_ocid" {
  description = "OCI user OCID for API key authentication"
  type        = string
  sensitive   = true
}

variable "oci_fingerprint" {
  description = "OCI API key fingerprint (MD5 hash of the public key)"
  type        = string
  sensitive   = true
}

variable "oci_private_key" {
  description = "OCI API private key PEM content"
  type        = string
  sensitive   = true
}

variable "network_access_policy" {
  # portainer_api removed: PORTAINER_API_URL now uses the Tailscale IP directly.
  # The public portainer-api Traefik route and its IP allowlist no longer exist.
  description = "Canonical network access policy for OCI SSH (IPv4)"
  type = object({
    oci_ssh = object({
      enabled       = bool
      source_ranges = list(string)
    })
  })

  validation {
    condition = (
      alltrue([for cidr in var.network_access_policy.oci_ssh.source_ranges : can(cidrhost(cidr, 0)) && !strcontains(cidr, ":")]) &&
      (!var.network_access_policy.oci_ssh.enabled || length(var.network_access_policy.oci_ssh.source_ranges) > 0)
    )
    error_message = "network_access_policy is invalid: oci_ssh.source_ranges must contain only valid IPv4 CIDRs."
  }
}

# Modules
module "oci" {
  source               = "../oci"
  oci_compartment_ocid = local.secrets.oci_compartment_id
  ssh_ca_public_key    = local.secrets.ssh_ca_public_key
  oci_image_ocid       = local.secrets.oci_image_ocid
  ssh_enabled          = var.network_access_policy.oci_ssh.enabled
  ssh_allowed_cidrs    = var.network_access_policy.oci_ssh.source_ranges
}

module "gcp" {
  source             = "../gcp"
  gcp_project        = local.secrets.gcp_project_id
  tailscale_auth_key = local.secrets.tailscale_auth_key
  # ssh_enabled and ssh_allowed_cidrs intentionally omitted — module defaults to ssh_enabled=false
}

# Outputs
output "oci_public_ips" {
  description = "Public IPv4 addresses of the OCI worker instances"
  value       = module.oci.public_worker_ips
}

output "gcp_witness_tailscale_hostname" {
  description = "Tailscale MagicDNS hostname of the GCP Swarm witness instance"
  value       = module.gcp.witness_tailscale_hostname
}
