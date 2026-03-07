#!/usr/bin/env bash
set -e

# Ensure you are logged into Infisical CLI and positioned in the correct project space
# e.g., infisical login

ENV="prod"

echo "Creating secrets for folder: /infrastructure"
infisical secrets set BASE_DOMAIN="example.com" --env=$ENV --path="/infrastructure" || true
infisical secrets set TZ="Etc/UTC" --env=$ENV --path="/infrastructure" || true
infisical secrets set CLOUDFLARE_API_TOKEN="your_cloudflare_api_token_here" --env=$ENV --path="/infrastructure" || true
infisical secrets set ZONE_ID="your_cloudflare_zone_id_here" --env=$ENV --path="/infrastructure" || true
infisical secrets set TAILSCALE_AUTH_KEY="your_tailscale_auth_key_here" --env=$ENV --path="/infrastructure" || true

echo "Creating secrets for folder: /management"
infisical secrets set PORTAINER_LICENSE_KEY="" --env=$ENV --path="/management" || true
echo "Skipping automation-managed /management secrets: PORTAINER_URL, PORTAINER_API_URL, PORTAINER_API_KEY"

echo "Creating secrets for folder: /deployments"
echo "Skipping automation-managed /deployments webhook secrets"

echo "Creating secrets for folder: /security"
infisical secrets set SSH_CA_PUBLIC_KEY="your_ssh_ca_public_key" --env=$ENV --path="/security" || true
infisical secrets set SSH_HOST_CA_PUBKEY="your_ssh_host_ca_pubkey" --env=$ENV --path="/security" || true

echo "Creating secrets for folder: /stacks/gateway"
infisical secrets set ACME_EMAIL="admin@example.com" --env=$ENV --path="/stacks/gateway" || true
infisical secrets set DOCKER_SOCKET_PROXY_URL="tcp://socket-proxy:2375" --env=$ENV --path="/stacks/gateway" || true

echo "Creating secrets for folder: /stacks/identity"
infisical secrets set AUTHELIA_JWT_SECRET="your_authelia_jwt_secret" --env=$ENV --path="/stacks/identity" || true
infisical secrets set AUTHELIA_SESSION_SECRET="your_authelia_session_secret" --env=$ENV --path="/stacks/identity" || true
infisical secrets set POSTGRES_PASSWORD="your_postgres_password" --env=$ENV --path="/stacks/identity" || true
infisical secrets set AUTHELIA_NOTIFIER_SMTP_USERNAME="your_smtp_username" --env=$ENV --path="/stacks/identity" || true
infisical secrets set AUTHELIA_NOTIFIER_SMTP_PASSWORD="your_smtp_password" --env=$ENV --path="/stacks/identity" || true
infisical secrets set AUTHELIA_NOTIFIER_SMTP_SENDER="Authelia <noreply@example.com>" --env=$ENV --path="/stacks/identity" || true
infisical secrets set AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET="your_authelia_oidc_hmac_secret" --env=$ENV --path="/stacks/identity" || true
infisical secrets set AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY="your_authelia_oidc_jwks_private_key_pem" --env=$ENV --path="/stacks/identity" || true

echo "Creating secrets for folder: /stacks/management"
infisical secrets set HOMARR_SECRET_KEY="your_homarr_secret_key" --env=$ENV --path="/stacks/management" || true
infisical secrets set PORTAINER_ADMIN_PASSWORD="your_portainer_admin_password" --env=$ENV --path="/stacks/management" || true
echo "Skipping automation-managed /stacks/management secrets: PORTAINER_ADMIN_PASSWORD_HASH, PORTAINER_AUTOMATION_ALLOWED_CIDRS"

echo "Creating secrets for folder: /stacks/network"
infisical secrets set VW_DB_PASS="your_vw_db_pass" --env=$ENV --path="/stacks/network" || true
infisical secrets set VW_ADMIN_TOKEN="your_vw_admin_token" --env=$ENV --path="/stacks/network" || true
infisical secrets set PIHOLE_PASSWORD="your_pihole_password" --env=$ENV --path="/stacks/network" || true

echo "Creating secrets for folder: /stacks/observability"
infisical secrets set GF_OIDC_CLIENT_ID="grafana" --env=$ENV --path="/stacks/observability" || true
infisical secrets set GF_OIDC_CLIENT_SECRET="your_gf_oidc_client_secret" --env=$ENV --path="/stacks/observability" || true
infisical secrets set ALERTMANAGER_WEBHOOK_URL="https://hooks.example.com/services/replace-me" --env=$ENV --path="/stacks/observability" || true

echo "Creating secrets for folder: /stacks/ai-interface"
infisical secrets set ARCH_PC_IP="your_arch_pc_ip" --env=$ENV --path="/stacks/ai-interface" || true

echo "Creating secrets for folder: /cloud-provider/oci"
infisical secrets set OCI_COMPARTMENT_OCID="your_oci_compartment_ocid" --env=$ENV --path="/cloud-provider/oci" || true
infisical secrets set OCI_IMAGE_OCID="your_oci_image_ocid" --env=$ENV --path="/cloud-provider/oci" || true

echo "Creating secrets for folder: /cloud-provider/gcp"
infisical secrets set GCP_PROJECT_ID="your_gcp_project_id" --env=$ENV --path="/cloud-provider/gcp" || true
