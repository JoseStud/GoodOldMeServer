#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

apt_install jq netcat-openbsd
setup_infisical

portainer_api_url="$(
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/management -- \
    bash -lc 'printf %s "${PORTAINER_API_URL:-}"'
)"

if [[ -z "${portainer_api_url}" ]]; then
  echo "PORTAINER_API_URL is missing in Infisical /management."
  exit 1
fi

PORTAINER_API_URL="${portainer_api_url}" \
WAIT_TIMEOUT_SECONDS="${PORTAINER_ALLOWLIST_PROPAGATION_TIMEOUT_SECONDS:-420}" \
POLL_INTERVAL_SECONDS="${PORTAINER_ALLOWLIST_PROPAGATION_POLL_INTERVAL_SECONDS:-5}" \
.github/scripts/network/wait_for_portainer_allowlist_propagation.sh

RUN_ANSIBLE="false" \
RUN_CONFIG="false" \
RUN_HEALTH="${RUN_HEALTH:-false}" \
RUN_PORTAINER="${RUN_PORTAINER:-false}" \
PORTAINER_API_URL="${portainer_api_url}" \
.github/scripts/network/preflight_network_access.sh
