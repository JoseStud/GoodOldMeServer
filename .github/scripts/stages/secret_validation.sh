#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

RUN_INFRA="${RUN_INFRA:-false}"
RUN_ANSIBLE="${RUN_ANSIBLE:-false}"
RUN_PORTAINER="${RUN_PORTAINER:-false}"
RUN_HOST_SYNC="${RUN_HOST_SYNC:-false}"
RUN_HEALTH="${RUN_HEALTH:-false}"

require_nonempty_env() {
  local name="$1"
  local value="${2:-}"

  if [[ -z "${value}" ]]; then
    echo "Missing required secret: ${name}"
    exit 1
  fi
}

validate_value_secret() {
  local path="$1"
  local name="$2"

  validate_infisical_secret "${path}" "${name}" value
}

validate_https_secret() {
  local path="$1"
  local name="$2"

  validate_infisical_secret "${path}" "${name}" https_url
}

validate_portainer_managed_stack_secrets() {
  validate_value_secret /infrastructure BASE_DOMAIN
  validate_value_secret /infrastructure TZ
  validate_value_secret /infrastructure CLOUDFLARE_API_TOKEN

  validate_value_secret /stacks/gateway ACME_EMAIL
  validate_value_secret /stacks/gateway DOCKER_SOCKET_PROXY_URL

  validate_value_secret /stacks/identity AUTHELIA_JWT_SECRET
  validate_value_secret /stacks/identity AUTHELIA_SESSION_SECRET
  validate_value_secret /stacks/identity POSTGRES_PASSWORD
  validate_value_secret /stacks/identity AUTHELIA_NOTIFIER_SMTP_USERNAME
  validate_value_secret /stacks/identity AUTHELIA_NOTIFIER_SMTP_PASSWORD
  validate_value_secret /stacks/identity AUTHELIA_NOTIFIER_SMTP_SENDER
  validate_value_secret /stacks/identity AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET
  validate_value_secret /stacks/identity AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY

  validate_value_secret /stacks/network VW_DB_PASS
  validate_value_secret /stacks/network VW_ADMIN_TOKEN
  validate_value_secret /stacks/network PIHOLE_PASSWORD

  validate_value_secret /stacks/observability GF_OIDC_CLIENT_ID
  validate_value_secret /stacks/observability GF_OIDC_CLIENT_SECRET
  validate_https_secret /stacks/observability ALERTMANAGER_WEBHOOK_URL

  validate_value_secret /stacks/ai-interface ARCH_PC_IP
}

validate_existing_portainer_credentials() {
  validate_https_secret /management PORTAINER_API_URL
  validate_value_secret /management PORTAINER_API_KEY
}

if [[ "${RUN_PORTAINER}" == "true" ]]; then
  require_nonempty_env "INFISICAL_TOKEN" "${INFISICAL_TOKEN:-}"
fi

if [[ "${RUN_ANSIBLE}" == "true" || "${RUN_HOST_SYNC}" == "true" ]]; then
  require_nonempty_env "INFISICAL_AGENT_CLIENT_ID" "${INFISICAL_AGENT_CLIENT_ID:-}"
  require_nonempty_env "INFISICAL_AGENT_CLIENT_SECRET" "${INFISICAL_AGENT_CLIENT_SECRET:-}"
fi

setup_infisical

if [[ "${RUN_INFRA}" == "true" ]]; then
  validate_value_secret /security SSH_CA_PUBLIC_KEY
  validate_value_secret /cloud-provider/oci OCI_COMPARTMENT_OCID
  validate_value_secret /cloud-provider/oci OCI_IMAGE_OCID
  validate_value_secret /cloud-provider/gcp GCP_PROJECT_ID
fi

if [[ "${RUN_ANSIBLE}" == "true" ]]; then
  validate_value_secret /infrastructure TAILSCALE_AUTH_KEY
  validate_value_secret /stacks/management HOMARR_SECRET_KEY
  validate_value_secret /stacks/management PORTAINER_ADMIN_PASSWORD
fi

if [[ "${RUN_ANSIBLE}" == "true" || "${RUN_PORTAINER}" == "true" || "${RUN_HEALTH}" == "true" ]]; then
  validate_portainer_managed_stack_secrets
fi

if [[ "${RUN_PORTAINER}" == "true" && "${RUN_ANSIBLE}" != "true" ]]; then
  validate_existing_portainer_credentials
fi

if [[ "${RUN_HEALTH}" == "true" ]]; then
  if [[ "${RUN_PORTAINER}" != "true" ]]; then
    validate_https_secret /deployments WEBHOOK_URL_GATEWAY
    validate_https_secret /deployments WEBHOOK_URL_AUTH
    validate_https_secret /deployments WEBHOOK_URL_NETWORK
    validate_https_secret /deployments WEBHOOK_URL_OBSERVABILITY
    validate_https_secret /deployments WEBHOOK_URL_AI_INTERFACE
    validate_https_secret /deployments WEBHOOK_URL_UPTIME
    validate_https_secret /deployments WEBHOOK_URL_CLOUD
  fi
fi
