#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

SHADOW_MODE="$(to_bool "${SHADOW_MODE:-false}")"

checkout_stacks_sha "${STACKS_SHA:-}"
setup_infisical

if [[ "${SHADOW_MODE}" == "true" ]]; then
  echo "SHADOW_MODE=true: skipping webhook trigger mutations."
  exit 0
fi

infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod -- bash -lc '
  .github/scripts/stacks/trigger_webhooks_with_gates.sh stacks/stacks.yaml
'
