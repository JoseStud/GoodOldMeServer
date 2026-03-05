#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${TFC_WORKSPACE_PORTAINER:?TFC_WORKSPACE_PORTAINER is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"

SHADOW_MODE="$(to_bool "${SHADOW_MODE:-false}")"

TFC_WORKSPACE="${TFC_WORKSPACE_PORTAINER}" \
.github/scripts/tfc/assert_tfc_workspace_local_mode.sh

terraform -chdir=terraform/portainer-root init -input=false \
  -backend-config="organization=${TFC_ORGANIZATION}" \
  -backend-config="workspaces.name=${TFC_WORKSPACE_PORTAINER}"

terraform -chdir=terraform/portainer-root plan -input=false -out=portainer.tfplan

if [[ "${SHADOW_MODE}" == "true" ]]; then
  echo "SHADOW_MODE=true: skipping Terraform apply for portainer workspace."
  exit 0
fi

terraform -chdir=terraform/portainer-root apply -input=false -auto-approve portainer.tfplan
