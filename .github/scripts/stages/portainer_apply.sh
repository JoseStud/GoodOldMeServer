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

SHADOW_MODE="$(to_bool "${SHADOW_MODE:-false}")"

TFC_WORKSPACE="${TFC_WORKSPACE_PORTAINER}" \
.github/scripts/tfc/assert_tfc_workspace_local_mode.sh

terraform_args=()
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
