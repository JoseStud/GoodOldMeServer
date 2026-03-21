#!/usr/bin/env bash
set -euo pipefail

# Ensure you are logged into Infisical CLI and export the target project ID
# e.g., infisical login && export INFISICAL_PROJECT_ID="<project-id>"

ENV="prod"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

set_secret() {
  local path="$1"
  shift

  infisical secrets set \
    "$@" \
    --env="${ENV}" \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --path="${path}" \
    || true
}

echo "Creating secrets for folder: /infrastructure"
set_secret "/infrastructure" BASE_DOMAIN="example.com"
set_secret "/infrastructure" TZ="Etc/UTC"
set_secret "/infrastructure" CLOUDFLARE_API_TOKEN="your_cloudflare_api_token_here"
set_secret "/infrastructure" ZONE_ID="your_cloudflare_zone_id_here"
set_secret "/infrastructure" TAILSCALE_AUTH_KEY="your_tailscale_auth_key_here"

echo "Creating secrets for folder: /management"
set_secret "/management" PORTAINER_LICENSE_KEY=""
echo "Skipping automation-managed /management secrets: PORTAINER_URL, PORTAINER_API_URL, PORTAINER_API_KEY"

echo "Creating secrets for folder: /deployments"
echo "Skipping automation-managed /deployments webhook secrets"

echo "Creating secrets for folder: /security"
set_secret "/security" SSH_CA_PUBLIC_KEY="your_ssh_ca_public_key"
set_secret "/security" SSH_CA_PRIVATE_KEY="your_ssh_ca_private_key"
set_secret "/security" SSH_HOST_CA_PUBKEY="your_ssh_host_ca_pubkey"

echo "Creating secrets for folder: /stacks/gateway"
set_secret "/stacks/gateway" ACME_EMAIL="admin@example.com"
set_secret "/stacks/gateway" DOCKER_SOCKET_PROXY_URL="tcp://tasks.socket-proxy:2375"

echo "Creating secrets for folder: /stacks/identity"
set_secret "/stacks/identity" AUTHELIA_JWT_SECRET="your_authelia_jwt_secret"
set_secret "/stacks/identity" AUTHELIA_SESSION_SECRET="your_authelia_session_secret"
set_secret "/stacks/identity" POSTGRES_PASSWORD="your_postgres_password"
set_secret "/stacks/identity" AUTHELIA_STORAGE_ENCRYPTION_KEY="your_authelia_storage_encryption_key"
set_secret "/stacks/identity" AUTHELIA_USERS_DATABASE_YAML="users: {}"
set_secret "/stacks/identity" AUTHELIA_NOTIFIER_SMTP_USERNAME="your_smtp_username"
set_secret "/stacks/identity" AUTHELIA_NOTIFIER_SMTP_PASSWORD="your_smtp_password"
set_secret "/stacks/identity" AUTHELIA_NOTIFIER_SMTP_SENDER="Authelia <noreply@example.com>"
set_secret "/stacks/identity" AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET="your_authelia_oidc_hmac_secret"
set_secret "/stacks/identity" AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY="your_authelia_oidc_jwks_private_key_pem"
set_secret "/stacks/identity" AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET="your_grafana_oidc_client_secret_hash"

echo "Creating secrets for folder: /stacks/management"
set_secret "/stacks/management" HOMARR_SECRET_KEY="your_homarr_secret_key"
set_secret "/stacks/management" PORTAINER_ADMIN_PASSWORD="your_portainer_admin_password"
echo "Skipping automation-managed /stacks/management secrets: PORTAINER_ADMIN_PASSWORD_HASH, PORTAINER_AUTOMATION_ALLOWED_CIDRS"

echo "Creating secrets for folder: /stacks/network"
set_secret "/stacks/network" VW_DB_PASS="your_vw_db_pass"
set_secret "/stacks/network" VW_ADMIN_TOKEN="your_vw_admin_token"
set_secret "/stacks/network" PIHOLE_PASSWORD="your_pihole_password"

echo "Creating secrets for folder: /stacks/observability"
set_secret "/stacks/observability" GF_OIDC_CLIENT_ID="grafana"
set_secret "/stacks/observability" GF_OIDC_CLIENT_SECRET="your_gf_oidc_client_secret"
set_secret "/stacks/observability" ALERTMANAGER_WEBHOOK_URL="https://hooks.example.com/services/replace-me"

echo "Creating secrets for folder: /stacks/ai-interface"
set_secret "/stacks/ai-interface" ARCH_PC_IP="your_arch_pc_ip"

echo "Creating secrets for folder: /cloud-provider/oci"
set_secret "/cloud-provider/oci" OCI_COMPARTMENT_OCID="your_oci_compartment_ocid"
set_secret "/cloud-provider/oci" OCI_IMAGE_OCID="your_oci_image_ocid"

echo "Creating secrets for folder: /cloud-provider/gcp"
set_secret "/cloud-provider/gcp" GCP_PROJECT_ID="your_gcp_project_id"
