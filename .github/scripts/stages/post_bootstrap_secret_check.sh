#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

setup_infisical

infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/management -- bash -lc '
  [[ -n "${PORTAINER_API_URL:-}" ]]
  [[ -n "${PORTAINER_API_KEY:-}" ]]
'
infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/stacks/management -- bash -lc '
  [[ -n "${PORTAINER_ADMIN_PASSWORD_HASH:-}" ]]
'
