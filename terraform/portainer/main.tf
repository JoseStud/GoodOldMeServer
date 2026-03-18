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
