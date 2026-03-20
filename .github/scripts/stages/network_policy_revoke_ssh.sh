#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

SHADOW_MODE="$(to_bool "${SHADOW_MODE:-false}")"

setup_infisical

policy_json='{"oci_ssh":{"enabled":false,"source_ranges":[]}}'

if [[ "${SHADOW_MODE}" == "true" ]]; then
  echo "SHADOW_MODE=true: skipping revoke of OCI SSH allow rules."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "network_access_policy_json=${policy_json}" >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

NETWORK_ACCESS_POLICY_JSON="${policy_json}" \
  .github/scripts/network/sync_network_access_policy.sh

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "network_access_policy_json=${policy_json}" >> "${GITHUB_OUTPUT}"
fi

echo "OCI SSH allow rules revoked (network_access_policy.oci_ssh.enabled=false)."