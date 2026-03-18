#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
: "${TFC_TOKEN:?TFC_TOKEN is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"
: "${TFC_WORKSPACE_PORTAINER:?TFC_WORKSPACE_PORTAINER is required}"

if [[ -z "${INFISICAL_TOKEN:-}" && -z "${INFISICAL_MACHINE_IDENTITY_ID:-}" ]]; then
  echo "Either INFISICAL_TOKEN or INFISICAL_MACHINE_IDENTITY_ID (OIDC) is required" >&2
  exit 1
fi

if [[ -z "${INFISICAL_TOKEN:-}" ]]; then
  INFISICAL_TOKEN="$(get_infisical_oidc_token)"
  export INFISICAL_TOKEN
fi

workspace_url="https://app.terraform.io/api/v2/organizations/${TFC_ORGANIZATION}/workspaces/${TFC_WORKSPACE_PORTAINER}"

echo "Portainer apply debug context:"
echo "  organization=${TFC_ORGANIZATION}"
echo "  workspace=${TFC_WORKSPACE_PORTAINER}"
echo "  workspace_url=${workspace_url}"
echo "  stacks_sha=${STACKS_SHA:-<unset>}"
echo "  shadow_mode=$(to_bool "${SHADOW_MODE:-false}")"
echo "  terraform_version=$(terraform version -json | jq -r '.terraform_version')"

workspace_json="$(
  curl -sSfL \
    -H "Authorization: Bearer ${TFC_TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    "${workspace_url}"
)"

echo "Terraform Cloud workspace attributes:"
jq '{
  id: .data.id,
  name: .data.attributes.name,
  operations: .data.attributes.operations,
  execution_mode: .data.attributes["execution-mode"],
  terraform_version: .data.attributes["terraform-version"],
  auto_apply: .data.attributes["auto-apply"],
  locked: .data.attributes.locked,
  vcs_repo_identifier: (.data.attributes["vcs-repo"].identifier // null),
  working_directory: .data.attributes["working-directory"]
}' <<<"${workspace_json}"

portainer_api_url="$(fetch_infisical_secret /management PORTAINER_API_URL)"
portainer_admin_user="${PORTAINER_ADMIN_USER:-admin}"
portainer_admin_password="$(fetch_infisical_secret /stacks/management PORTAINER_ADMIN_PASSWORD)"
portainer_jwt="$(get_portainer_jwt "${portainer_api_url}" "${portainer_admin_user}" "${portainer_admin_password}")"

if [[ -z "${portainer_jwt}" ]]; then
  echo "Portainer endpoint debug: authentication failed while resolving environments."
  exit 1
fi

endpoints_json="$(
  curl -sSf \
    -H "Authorization: Bearer ${portainer_jwt}" \
    "${portainer_api_url%/}/endpoints"
)"

echo "Portainer environments:"
jq '[.[] | {id: .Id, name: .Name, type: .Type, url: .URL}]' <<<"${endpoints_json}"

resolved_endpoint_id="$(resolve_portainer_endpoint_id "${portainer_api_url}" "${portainer_jwt}")"
echo "Resolved Portainer environment ID: ${resolved_endpoint_id}"
