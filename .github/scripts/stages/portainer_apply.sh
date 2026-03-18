#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

if [[ -z "${INFISICAL_TOKEN:-}" && -z "${INFISICAL_MACHINE_IDENTITY_ID:-}" ]]; then
  echo "Either INFISICAL_TOKEN or INFISICAL_MACHINE_IDENTITY_ID (OIDC) is required" >&2
  exit 1
fi

if [[ -z "${INFISICAL_TOKEN:-}" ]]; then
  INFISICAL_TOKEN="$(get_infisical_oidc_token)"
  export INFISICAL_TOKEN
fi
: "${TFC_WORKSPACE_PORTAINER:?TFC_WORKSPACE_PORTAINER is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

SHADOW_MODE="$(to_bool "${SHADOW_MODE:-false}")"

portainer_api_url="$(fetch_infisical_secret /management PORTAINER_API_URL)"
portainer_admin_user="${PORTAINER_ADMIN_USER:-admin}"
portainer_admin_password="$(fetch_infisical_secret /stacks/management PORTAINER_ADMIN_PASSWORD)"
portainer_jwt="$(get_portainer_jwt "${portainer_api_url}" "${portainer_admin_user}" "${portainer_admin_password}")"
if [[ -z "${portainer_jwt}" ]]; then
  echo "Failed to authenticate to Portainer while resolving the environment ID." >&2
  exit 1
fi

portainer_endpoint_id="$(resolve_portainer_endpoint_id "${portainer_api_url}" "${portainer_jwt}")"
echo "Resolved Portainer environment ID: ${portainer_endpoint_id}"

TFC_WORKSPACE="${TFC_WORKSPACE_PORTAINER}" \
.github/scripts/tfc/assert_tfc_workspace_local_mode.sh

terraform_args=()
terraform_args+=("TF_VAR_portainer_endpoint_id=${portainer_endpoint_id}")
if [[ -n "${STACKS_SHA:-}" ]]; then
  terraform_args+=("TF_VAR_stacks_sha=${STACKS_SHA}")
fi

backend_config_file="$(mktemp)"
trap 'rm -f "${backend_config_file}"' EXIT

cat >"${backend_config_file}" <<EOF
organization = "${TFC_ORGANIZATION}"

workspaces {
  name = "${TFC_WORKSPACE_PORTAINER}"
}
EOF

env "${terraform_args[@]}" terraform -chdir=terraform/portainer-root init -input=false -reconfigure \
  -backend-config="${backend_config_file}"

env "${terraform_args[@]}" terraform -chdir=terraform/portainer-root plan -input=false -out=portainer.tfplan

if [[ "${SHADOW_MODE}" == "true" ]]; then
  echo "SHADOW_MODE=true: skipping Terraform apply for portainer workspace."
  exit 0
fi

env "${terraform_args[@]}" terraform -chdir=terraform/portainer-root apply -input=false -auto-approve portainer.tfplan
