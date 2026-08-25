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

# TEMPORARY ONE-TIME IMPORT (2026-08-25): a run from 2026-03-23 got stuck
# "pending confirmation" for ~5 months, holding a lock that blocked all state
# writes; by the time it was discarded, a prior partial apply had already
# created the real "home-dashboard" Portainer stack (id 33, the Tunet app)
# without ever recording it in state. Every apply since has tried to
# recreate it and failed. This import teaches Terraform about the
# already-existing stack so it stops trying to recreate it. Safe to run
# repeatedly (a no-op "resource already managed" error is ignored) — revert
# this block once confirmed no longer needed.
env "${terraform_args[@]}" terraform -chdir=terraform/portainer-root import \
  'module.portainer.portainer_stack.swarm["home-dashboard"]' "${portainer_endpoint_id}-33-swarm-repository" || true
env "${terraform_args[@]}" terraform -chdir=terraform/portainer-root import \
  'module.portainer.infisical_secret.webhook_url["home-dashboard"]' 91278e2a-9b94-4f77-9ec6-4cde755ce522 || true

plan_exit=0
env "${terraform_args[@]}" terraform -chdir=terraform/portainer-root plan -input=false -out=portainer.tfplan -detailed-exitcode || plan_exit=$?

if [[ "${plan_exit}" -eq 1 ]]; then
  echo "Terraform plan failed." >&2
  exit 1
fi

if [[ "${plan_exit}" -eq 0 ]]; then
  echo "Terraform plan shows no changes — skipping apply."
  exit 0
fi

if [[ "${SHADOW_MODE}" == "true" ]]; then
  echo "SHADOW_MODE=true: skipping Terraform apply for portainer workspace."
  exit 0
fi

env "${terraform_args[@]}" terraform -chdir=terraform/portainer-root apply -input=false -auto-approve portainer.tfplan
