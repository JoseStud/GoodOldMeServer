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

validate_portainer_managed_stack_secrets() {
  require_infisical_secrets /infrastructure \
    BASE_DOMAIN \
    TZ \
    CLOUDFLARE_API_TOKEN

  require_infisical_secrets /stacks/gateway \
    ACME_EMAIL \
    DOCKER_SOCKET_PROXY_URL

  require_infisical_secrets /stacks/identity \
    AUTHELIA_JWT_SECRET \
    AUTHELIA_SESSION_SECRET \
    POSTGRES_PASSWORD \
    AUTHELIA_NOTIFIER_SMTP_USERNAME \
    AUTHELIA_NOTIFIER_SMTP_PASSWORD \
    AUTHELIA_NOTIFIER_SMTP_SENDER \
    AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET \
    AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY

  require_infisical_secrets /stacks/network \
    VW_DB_PASS \
    VW_ADMIN_TOKEN \
    PIHOLE_PASSWORD

  require_infisical_secrets /stacks/observability \
    GF_OIDC_CLIENT_ID \
    GF_OIDC_CLIENT_SECRET \
    ALERTMANAGER_WEBHOOK_URL

  require_infisical_secrets /stacks/ai-interface \
    ARCH_PC_IP
}

validate_existing_portainer_credentials() {
  local portainer_api_url
  local portainer_api_key

  portainer_api_url="$(fetch_infisical_secret /management PORTAINER_API_URL)"
  portainer_api_key="$(fetch_infisical_secret /management PORTAINER_API_KEY)"

  assert_https_url_value "PORTAINER_API_URL" "${portainer_api_url}"
  assert_nonplaceholder_value "PORTAINER_API_KEY" "${portainer_api_key}"
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
  require_infisical_secrets /security SSH_CA_PUBLIC_KEY
  require_infisical_secrets /cloud-provider/oci OCI_COMPARTMENT_OCID OCI_IMAGE_OCID
  require_infisical_secrets /cloud-provider/gcp GCP_PROJECT_ID
fi

if [[ "${RUN_ANSIBLE}" == "true" ]]; then
  require_infisical_secrets /infrastructure TAILSCALE_AUTH_KEY
  require_infisical_secrets /stacks/management HOMARR_SECRET_KEY PORTAINER_ADMIN_PASSWORD
fi

if [[ "${RUN_ANSIBLE}" == "true" || "${RUN_PORTAINER}" == "true" || "${RUN_HEALTH}" == "true" ]]; then
  validate_portainer_managed_stack_secrets
fi

if [[ "${RUN_PORTAINER}" == "true" && "${RUN_ANSIBLE}" != "true" ]]; then
  validate_existing_portainer_credentials
fi

if [[ "${RUN_HEALTH}" == "true" ]]; then
  if [[ "${RUN_PORTAINER}" != "true" ]]; then
    require_infisical_secrets /deployments \
      WEBHOOK_URL_GATEWAY \
      WEBHOOK_URL_AUTH \
      WEBHOOK_URL_NETWORK \
      WEBHOOK_URL_OBSERVABILITY \
      WEBHOOK_URL_AI_INTERFACE \
      WEBHOOK_URL_UPTIME \
      WEBHOOK_URL_CLOUD
  fi
fi
