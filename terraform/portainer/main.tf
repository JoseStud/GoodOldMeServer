terraform {
  required_providers {
    portainer = { source = "portainer/portainer", version = "~> 1.0" }
    infisical = { source = "Infisical/infisical", version = ">= 0.8.0" }
    http      = { source = "hashicorp/http", version = ">= 3.0.0" }
  }
}

# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────

variable "endpoint_id" {
  description = "Portainer environment (endpoint) ID for the Swarm cluster"
  type        = number
  default     = 1
}

variable "repository_url" {
  description = "Git repository URL containing the stack compose files"
  type        = string
}

variable "repository_reference" {
  description = "Git reference to deploy from"
  type        = string
  default     = "refs/heads/main"
}

variable "stacks_sha" {
  description = "Optional immutable stacks repository commit SHA that overrides stacks_manifest_url only"
  type        = string
  default     = null

  validation {
    condition     = var.stacks_sha == null || can(regex("^[0-9a-f]{40}$", var.stacks_sha))
    error_message = "stacks_sha must be null or a 40-character lowercase hexadecimal commit SHA."
  }
}

variable "infisical_project_id" {
  description = "Infisical project/workspace ID for writing webhook URLs"
  type        = string
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

variable "license_key" {
  description = "Portainer Business Edition license key (optional — leave empty to skip)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "stacks_manifest_url" {
  description = "URL of the stacks manifest (stacks.yaml) used to define Portainer-managed stacks"
  type        = string
  default     = "https://raw.githubusercontent.com/JoseStud/stacks/main/stacks.yaml"
}

variable "stacks_manifest_token" {
  description = "Optional bearer token used to fetch a private stacks manifest URL"
  type        = string
  default     = null
  sensitive   = true
}

# ──────────────────────────────────────────────
# Stack Definitions
# ──────────────────────────────────────────────

data "http" "stacks_manifest" {
  url = local.effective_stacks_manifest_url

  request_headers = var.stacks_manifest_token != null && trimspace(var.stacks_manifest_token) != "" ? {
    Authorization = "Bearer ${var.stacks_manifest_token}"
  } : {}
}

data "infisical_secrets" "infrastructure" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/infrastructure"
}

data "infisical_secrets" "gateway" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/stacks/gateway"
}

data "infisical_secrets" "identity" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/stacks/identity"
}

data "infisical_secrets" "network" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/stacks/network"
}

data "infisical_secrets" "observability" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/stacks/observability"
}

data "infisical_secrets" "ai_interface" {
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/stacks/ai-interface"
}

locals {
  has_stacks_sha = var.stacks_sha != null
  github_repo_path = startswith(var.repository_url, "https://github.com/") ? trimprefix(var.repository_url, "https://github.com/") : (
    startswith(var.repository_url, "git@github.com:") ? trimprefix(var.repository_url, "git@github.com:") : ""
  )
  github_repo_path_trimmed = trimsuffix(local.github_repo_path, ".git")
  github_repo_parts        = local.github_repo_path_trimmed != "" ? split("/", local.github_repo_path_trimmed) : []
  github_repo_valid = length(local.github_repo_parts) == 2 && alltrue([
    for part in local.github_repo_parts :
    trimspace(part) != ""
  ])
  github_repo_owner = local.github_repo_valid ? local.github_repo_parts[0] : null
  github_repo_name  = local.github_repo_valid ? local.github_repo_parts[1] : null
  effective_stacks_manifest_url = local.has_stacks_sha ? (
    local.github_repo_valid ? "https://raw.githubusercontent.com/${local.github_repo_owner}/${local.github_repo_name}/${var.stacks_sha}/stacks.yaml" : var.stacks_manifest_url
  ) : var.stacks_manifest_url
  stacks_manifest = yamldecode(data.http.stacks_manifest.response_body)
  stack_entries   = try(local.stacks_manifest.stacks, {})

  # Map of stack name -> compose file path for Portainer-managed stacks only.
  stacks = {
    for name, cfg in local.stack_entries :
    name => cfg.compose_path
    if try(cfg.portainer_managed, false)
  }

  infrastructure_secrets = { for key, secret in data.infisical_secrets.infrastructure.secrets : key => secret.value }
  gateway_secrets        = { for key, secret in data.infisical_secrets.gateway.secrets : key => secret.value }
  identity_secrets       = { for key, secret in data.infisical_secrets.identity.secrets : key => secret.value }
  network_secrets        = { for key, secret in data.infisical_secrets.network.secrets : key => secret.value }
  observability_secrets  = { for key, secret in data.infisical_secrets.observability.secrets : key => secret.value }
  ai_interface_secrets   = { for key, secret in data.infisical_secrets.ai_interface.secrets : key => secret.value }

  portainer_stack_envs = {
    gateway = {
      BASE_DOMAIN             = local.infrastructure_secrets["BASE_DOMAIN"]
      CLOUDFLARE_API_TOKEN    = local.infrastructure_secrets["CLOUDFLARE_API_TOKEN"]
      ACME_EMAIL              = local.gateway_secrets["ACME_EMAIL"]
      DOCKER_SOCKET_PROXY_URL = try(local.gateway_secrets["DOCKER_SOCKET_PROXY_URL"], "")
    }
    auth = {
      BASE_DOMAIN                                    = local.infrastructure_secrets["BASE_DOMAIN"]
      TZ                                             = local.infrastructure_secrets["TZ"]
      AUTHELIA_JWT_SECRET                            = local.identity_secrets["AUTHELIA_JWT_SECRET"]
      AUTHELIA_SESSION_SECRET                        = local.identity_secrets["AUTHELIA_SESSION_SECRET"]
      POSTGRES_PASSWORD                              = local.identity_secrets["POSTGRES_PASSWORD"]
      AUTHELIA_STORAGE_ENCRYPTION_KEY                = local.identity_secrets["AUTHELIA_STORAGE_ENCRYPTION_KEY"]
      AUTHELIA_NOTIFIER_SMTP_USERNAME                = local.identity_secrets["AUTHELIA_NOTIFIER_SMTP_USERNAME"]
      AUTHELIA_NOTIFIER_SMTP_PASSWORD                = local.identity_secrets["AUTHELIA_NOTIFIER_SMTP_PASSWORD"]
      AUTHELIA_NOTIFIER_SMTP_SENDER                  = local.identity_secrets["AUTHELIA_NOTIFIER_SMTP_SENDER"]
      AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET   = local.identity_secrets["AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET"]
      AUTH_OIDC_JWKS_0_KEY                           = local.identity_secrets["AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY"]
      AUTH_GRAFANA_OIDC_CLIENT_SECRET_HASH           = local.identity_secrets["AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET"]
      AUTH_SESSION_COOKIES_0_DOMAIN                  = local.infrastructure_secrets["BASE_DOMAIN"]
      AUTH_SESSION_COOKIES_0_AUTHELIA_URL            = "https://auth.${local.infrastructure_secrets["BASE_DOMAIN"]}"
      AUTH_SESSION_COOKIES_0_DEFAULT_REDIRECTION_URL = "https://home.${local.infrastructure_secrets["BASE_DOMAIN"]}"
      AUTHELIA_TOTP_ISSUER                           = local.infrastructure_secrets["BASE_DOMAIN"]
    }
    network = {
      BASE_DOMAIN     = local.infrastructure_secrets["BASE_DOMAIN"]
      TZ              = local.infrastructure_secrets["TZ"]
      VW_DB_PASS      = local.network_secrets["VW_DB_PASS"]
      VW_ADMIN_TOKEN  = local.network_secrets["VW_ADMIN_TOKEN"]
      PIHOLE_PASSWORD = local.network_secrets["PIHOLE_PASSWORD"]
    }
    observability = {
      BASE_DOMAIN           = local.infrastructure_secrets["BASE_DOMAIN"]
      TZ                    = local.infrastructure_secrets["TZ"]
      GF_OIDC_CLIENT_ID     = local.observability_secrets["GF_OIDC_CLIENT_ID"]
      GF_OIDC_CLIENT_SECRET = local.observability_secrets["GF_OIDC_CLIENT_SECRET"]
    }
    "ai-interface" = {
      BASE_DOMAIN = local.infrastructure_secrets["BASE_DOMAIN"]
      TZ          = local.infrastructure_secrets["TZ"]
      ARCH_PC_IP  = try(local.ai_interface_secrets["ARCH_PC_IP"], "")
    }
    uptime = {
      BASE_DOMAIN = local.infrastructure_secrets["BASE_DOMAIN"]
      TZ          = local.infrastructure_secrets["TZ"]
    }
    cloud = {
      BASE_DOMAIN = local.infrastructure_secrets["BASE_DOMAIN"]
      TZ          = local.infrastructure_secrets["TZ"]
    }
  }

  has_git_auth = var.git_username != null && var.git_password != null
}

check "stacks_sha_requires_github_repository_url" {
  assert {
    condition     = !local.has_stacks_sha || local.github_repo_valid
    error_message = "stacks_sha requires repository_url to use https://github.com/<owner>/<repo>.git or git@github.com:<owner>/<repo>.git format so Terraform can derive the raw GitHub manifest URL."
  }
}

check "stacks_manifest_version" {
  assert {
    condition     = try(local.stacks_manifest.version, 0) == 1
    error_message = "stacks.yaml must define version: 1."
  }
}

check "stacks_manifest_compose_paths" {
  assert {
    condition = alltrue([
      for name, cfg in local.stacks :
      trimspace(cfg) != ""
    ])
    error_message = "All portainer_managed stacks in stacks.yaml must define a non-empty compose_path."
  }
}

check "portainer_stack_envs_cover_all_managed_stacks" {
  assert {
    condition = alltrue([
      for name in keys(local.stacks) :
      contains(keys(local.portainer_stack_envs), name)
    ])
    error_message = "Every Portainer-managed stack in stacks.yaml must have a corresponding env map in local.portainer_stack_envs."
  }
}

# ──────────────────────────────────────────────
# Portainer Stacks (Swarm + GitOps)
# ──────────────────────────────────────────────

resource "portainer_stack" "swarm" {
  for_each = local.stacks

  name            = each.key
  deployment_type = "swarm"
  method          = "repository"
  endpoint_id     = var.endpoint_id

  repository_url            = var.repository_url
  repository_reference_name = var.repository_reference
  file_path_in_repository   = each.value

  # GitOps: enable webhook + pull latest images on redeploy
  stack_webhook = true
  pull_image    = true
  force_update  = true

  # Private repository credentials (optional)
  git_repository_authentication = local.has_git_auth
  repository_username           = local.has_git_auth ? var.git_username : null
  repository_password           = local.has_git_auth ? var.git_password : null

  dynamic "env" {
    for_each = local.portainer_stack_envs[each.key]

    content {
      name  = env.key
      value = env.value
    }
  }
}

# ──────────────────────────────────────────────
# Portainer License (Business Edition)
# ──────────────────────────────────────────────

resource "portainer_licenses" "be" {
  count = var.license_key != "" ? 1 : 0

  key   = var.license_key
  force = true
}

# ──────────────────────────────────────────────
# Infisical — Webhook URLs → /deployments
# ──────────────────────────────────────────────

# Individual webhook URL per stack (e.g. WEBHOOK_URL_GATEWAY, WEBHOOK_URL_AUTH)
resource "infisical_secret" "webhook_url" {
  for_each = portainer_stack.swarm

  name         = "WEBHOOK_URL_${upper(replace(each.key, "-", "_"))}"
  value        = each.value.webhook_url
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/deployments"
}

# Combined comma-separated list for portainer-webhook.sh compatibility
resource "infisical_secret" "webhook_urls_combined" {
  name         = "PORTAINER_WEBHOOK_URLS"
  value        = join(",", [for name, stack in portainer_stack.swarm : stack.webhook_url])
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/deployments"
}

# ──────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────

output "webhook_urls" {
  description = "Map of stack names to their GitOps webhook URLs"
  value       = { for name, stack in portainer_stack.swarm : name => stack.webhook_url }
  sensitive   = true
}

output "stack_ids" {
  description = "Map of stack names to their Portainer stack IDs"
  value       = { for name, stack in portainer_stack.swarm : name => stack.id }
}
