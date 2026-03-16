terraform {
  required_version = ">= 1.5.0"

  backend "remote" {}

  required_providers {
    infisical = { source = "Infisical/infisical", version = ">= 0.8.0" }
    portainer = { source = "portainer/portainer", version = "~> 1.0" }
  }
}

# Providers
provider "infisical" {
  host = "https://app.infisical.com"

  dynamic "oidc_auth" {
    for_each = var.infisical_machine_identity_id != null ? [1] : []
    content {
      identity_id = var.infisical_machine_identity_id
    }
  }
}

provider "portainer" {
  endpoint = local.secrets.portainer_api_url
  api_key  = local.secrets.portainer_api_key
}

# Secrets from Infisical
data "infisical_secrets" "management" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/management"
}

locals {
  secrets = {
    portainer_api_url     = data.infisical_secrets.management.secrets["PORTAINER_API_URL"].value
    portainer_api_key     = data.infisical_secrets.management.secrets["PORTAINER_API_KEY"].value
    portainer_license_key = try(data.infisical_secrets.management.secrets["PORTAINER_LICENSE_KEY"].value, "")
  }
}

# Variables
variable "infisical_machine_identity_id" {
  description = "Infisical machine identity ID for OIDC authentication (optional; INFISICAL_TOKEN takes precedence)"
  type        = string
  default     = null
}

variable "infisical_project_id" {
  description = "Infisical workspace/project ID for secret retrieval"
  type        = string
}

variable "portainer_endpoint_id" {
  description = "Portainer environment (endpoint) ID for the Swarm cluster"
  type        = number
  default     = 1
}

variable "repository_url" {
  description = "Git repository URL containing the stack compose files"
  type        = string
  default     = "https://github.com/JoseStud/stacks.git"
}

variable "repository_reference" {
  description = "Git reference to deploy from"
  type        = string
  default     = "refs/heads/main"
}

variable "stacks_sha" {
  description = "Optional immutable stacks repository commit SHA that overrides repository_reference and stacks_manifest_url"
  type        = string
  default     = null

  validation {
    condition     = var.stacks_sha == null || can(regex("^[0-9a-f]{40}$", var.stacks_sha))
    error_message = "stacks_sha must be null or a 40-character lowercase hexadecimal commit SHA."
  }
}

variable "git_username" {
  description = "Git username for private repository authentication (optional)"
  type        = string
  default     = null
}

variable "git_password" {
  description = "Git password or PAT for private repository authentication (optional)"
  type        = string
  default     = null
  sensitive   = true
}

variable "stacks_manifest_url" {
  description = "URL of the stacks manifest (stacks.yaml) used by the Portainer module"
  type        = string
  default     = "https://raw.githubusercontent.com/JoseStud/stacks/main/stacks.yaml"
}

variable "stacks_manifest_token" {
  description = "Optional bearer token used to fetch a private stacks manifest URL"
  type        = string
  default     = null
  sensitive   = true
}

# Modules
module "portainer" {
  source                = "../portainer"
  endpoint_id           = var.portainer_endpoint_id
  repository_url        = var.repository_url
  repository_reference  = var.repository_reference
  stacks_sha            = var.stacks_sha
  infisical_project_id  = var.infisical_project_id
  git_username          = var.git_username
  git_password          = var.git_password
  stacks_manifest_url   = var.stacks_manifest_url
  stacks_manifest_token = var.stacks_manifest_token
  license_key           = local.secrets.portainer_license_key
}

# Outputs
output "portainer_webhook_urls" {
  description = "Map of stack names to their Portainer GitOps webhook URLs"
  value       = module.portainer.webhook_urls
  sensitive   = true
}

output "portainer_stack_ids" {
  description = "Map of stack names to their Portainer stack IDs"
  value       = module.portainer.stack_ids
}
