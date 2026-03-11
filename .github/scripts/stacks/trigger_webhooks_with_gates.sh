#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <manifest_path>"
  exit 1
fi

MANIFEST_PATH="$1"

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  echo "Manifest not found: ${MANIFEST_PATH}"
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required but was not found in PATH."
  exit 1
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

declare -A TARGET_STACKS=()

load_full_reconcile_targets() {
  local stack

  while IFS= read -r stack; do
    stack="$(trim "${stack}")"
    [[ -z "${stack}" ]] && continue
    TARGET_STACKS["${stack}"]=1
  done < <(yq -r '.stacks | to_entries[] | select(.value.portainer_managed == true) | .key' "${MANIFEST_PATH}")

  if [[ ${#TARGET_STACKS[@]} -eq 0 ]]; then
    echo "No Portainer-managed stacks found in ${MANIFEST_PATH}."
    exit 1
  fi
}

if ! command -v gomplate >/dev/null 2>&1; then
  echo "gomplate is required but was not found in PATH."
  exit 1
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workflow_common.sh"

echo "Full reconcile: redeploying all Portainer-managed stacks."
load_full_reconcile_targets

render_url() {
  local raw_url="$1"
  printf '%s' "${raw_url}" | gomplate
}

wait_for_stack_health() {
  local stack="$1"
  local health_url expected timeout deadline status

  health_url="$(yq -r ".stacks.\"${stack}\".healthcheck_url // \"\"" "${MANIFEST_PATH}")"
  [[ -z "${health_url}" ]] && return 0

  health_url="$(render_url "${health_url}")"
  expected="$(yq -r ".stacks.\"${stack}\".healthcheck_expected_status // 200" "${MANIFEST_PATH}")"
  timeout="$(yq -r ".stacks.\"${stack}\".healthcheck_timeout_seconds // 300" "${MANIFEST_PATH}")"
  deadline=$((SECONDS + timeout))

  echo "Waiting for ${stack} health: ${health_url} (expected ${expected})"
  while true; do
    status="$(curl -sSo /dev/null -w "%{http_code}" --max-time 10 "${health_url}" || true)"
    if [[ "${status}" == "${expected}" ]]; then
      echo "Health check passed for ${stack} (HTTP ${status})."
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "Health check timed out for ${stack}. Last status: ${status}."
      return 1
    fi
    sleep 5
  done
}

trigger_stack_webhook() {
  local stack="$1"
  local env_name url status
  local max_attempts=3

  env_name="WEBHOOK_URL_$(echo "${stack}" | tr '[:lower:]-' '[:upper:]_')"
  url="${!env_name:-}"
  if [[ -z "${url}" ]]; then
    echo "Missing ${env_name} for stack '${stack}'."
    return 1
  fi

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    status="$(curl -sSo /dev/null -w "%{http_code}" -X POST "${url}" || echo "000")"
    if [[ "${status}" =~ ^2 ]]; then
      echo "Triggered webhook for ${stack} (HTTP ${status})."
      return 0
    fi

    # Retry on 5xx (server-side transient) or 000 (network error); fail
    # immediately on 4xx or other client errors.
    if [[ "${status}" =~ ^5 || "${status}" == "000" ]] && (( attempt < max_attempts )); then
      local delay=$(( 2 ** attempt ))
      echo "Webhook call for ${stack} returned HTTP ${status}; retrying in ${delay}s (attempt ${attempt}/${max_attempts})..."
      sleep "${delay}"
      continue
    fi

    echo "Webhook call failed for ${stack} (HTTP ${status}) after ${attempt} attempt(s)."
    return 1
  done
}

declare -A VISITING=()
declare -A VISITED=()
ORDERED_STACKS=()

visit_stack() {
  local stack="$1"
  local dep

  if [[ -n "${VISITED[${stack}]:-}" ]]; then
    return 0
  fi
  if [[ -n "${VISITING[${stack}]:-}" ]]; then
    echo "Dependency cycle detected at stack '${stack}'."
    return 1
  fi

  VISITING["${stack}"]=1
  while IFS= read -r dep; do
    dep="$(trim "${dep}")"
    [[ -z "${dep}" ]] && continue
    if [[ -n "${TARGET_STACKS[${dep}]:-}" ]]; then
      visit_stack "${dep}"
    fi
  done < <(yq -r ".stacks.\"${stack}\".depends_on[]?" "${MANIFEST_PATH}")

  unset VISITING["${stack}"]
  VISITED["${stack}"]=1
  ORDERED_STACKS+=("${stack}")
}

mapfile -t INPUT_STACKS < <(yq -r '.stacks | to_entries[] | select(.value.portainer_managed == true) | .key' "${MANIFEST_PATH}")

for stack in "${INPUT_STACKS[@]}"; do
  visit_stack "${stack}"
done

# Overall deadline caps total wall time for the entire redeploy.
# Individual per-stack timeouts guard single-stack hangs; this guards the aggregate.
REDEPLOY_TIMEOUT_SECONDS="${REDEPLOY_TIMEOUT_SECONDS:-2400}"
redeploy_deadline=$((SECONDS + REDEPLOY_TIMEOUT_SECONDS))

for stack in "${ORDERED_STACKS[@]}"; do
  if (( SECONDS >= redeploy_deadline )); then
    echo "Overall redeploy deadline exceeded (${REDEPLOY_TIMEOUT_SECONDS}s). Aborting remaining stacks."
    exit 1
  fi
  while IFS= read -r dep; do
    dep="$(trim "${dep}")"
    [[ -z "${dep}" ]] && continue
    wait_for_stack_health "${dep}"
  done < <(yq -r ".stacks.\"${stack}\".depends_on[]?" "${MANIFEST_PATH}")

  trigger_stack_webhook "${stack}"
  wait_for_stack_health "${stack}"
done

echo "Health-gated webhook redeploy completed."
