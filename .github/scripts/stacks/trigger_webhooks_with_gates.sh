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

is_true() {
  case "${1,,}" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
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

echo "Full reconcile: redeploying all Portainer-managed stacks."
load_full_reconcile_targets

render_url() {
  local raw_url="$1"
  local rendered="${raw_url}"
  if [[ "${rendered}" == *'${BASE_DOMAIN}'* ]]; then
    if [[ -z "${BASE_DOMAIN:-}" ]]; then
      echo "BASE_DOMAIN is required to render healthcheck URL '${raw_url}'."
      exit 1
    fi
    rendered="${rendered//'${BASE_DOMAIN}'/${BASE_DOMAIN}}"
  fi
  printf '%s' "${rendered}"
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

  env_name="WEBHOOK_URL_$(echo "${stack}" | tr '[:lower:]-' '[:upper:]_')"
  url="${!env_name:-}"
  if [[ -z "${url}" ]]; then
    echo "Missing ${env_name} for stack '${stack}'."
    return 1
  fi

  status="$(curl -sSo /dev/null -w "%{http_code}" -X POST "${url}")"
  if [[ "${status}" != "200" && "${status}" != "204" ]]; then
    echo "Webhook call failed for ${stack} (HTTP ${status})."
    return 1
  fi

  echo "Triggered webhook for ${stack} (HTTP ${status})."
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

for stack in "${ORDERED_STACKS[@]}"; do
  while IFS= read -r dep; do
    dep="$(trim "${dep}")"
    [[ -z "${dep}" ]] && continue
    wait_for_stack_health "${dep}"
  done < <(yq -r ".stacks.\"${stack}\".depends_on[]?" "${MANIFEST_PATH}")

  trigger_stack_webhook "${stack}"
  wait_for_stack_health "${stack}"
done

echo "Health-gated webhook redeploy completed."
