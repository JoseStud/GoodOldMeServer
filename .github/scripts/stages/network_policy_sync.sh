#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

SHADOW_MODE="$(to_bool "${SHADOW_MODE:-false}")"

apt_install jq
setup_infisical

policy_json="$({
  BREAK_GLASS_POLICY_JSON="${BREAK_GLASS_POLICY_JSON:-}" \
  BREAK_GLASS_POLICY_FILE="${BREAK_GLASS_POLICY_FILE:-}" \
  .github/scripts/network/build_network_access_policy.sh
} | tail -n1)"

if [[ -z "${policy_json}" ]]; then
  echo "Failed to build network_access_policy JSON."
  exit 1
fi

if [[ "${SHADOW_MODE}" == "true" ]]; then
  echo "SHADOW_MODE=true: skipping sync_network_access_policy.sh mutation steps."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    portainer_cidrs_csv="$(jq -r '.portainer_api.source_ranges | join(",")' <<<"${policy_json}")"
    {
      echo "network_access_policy_json=${policy_json}"
      echo "portainer_automation_allowed_cidrs=${portainer_cidrs_csv}"
    } >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

NETWORK_ACCESS_POLICY_JSON="${policy_json}" \
  .github/scripts/network/sync_network_access_policy.sh
