#!/usr/bin/env bash

set -euo pipefail

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

normalize_csv() {
  local input="$1"
  input="$(echo "${input}" | tr -d '\r')"
  if [[ -z "${input}" || "${input}" == "null" ]]; then
    echo ""
    return
  fi

  IFS=',' read -ra parts <<< "${input}"
  if [[ ${#parts[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  printf '%s\n' "${parts[@]}" \
    | awk '{$1=$1; print}' \
    | awk 'NF > 0' \
    | awk '!seen[$0]++' \
    | sort \
    | paste -sd, -
}

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

normalize_nullable() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo ""
    return
  fi
  echo "${value}"
}

derive_push_flags_from_changed_files() {
  local changed_files="$1"

  if grep -Eq '^terraform/(infra|oci|gcp)/' <<<"${changed_files}"; then
    run_infra_apply="true"
  fi

  if grep -Eq '(^ansible/|^\.ansible-lint$)' <<<"${changed_files}"; then
    run_ansible_bootstrap="true"
  fi

  if grep -Eq '^(terraform/portainer/|terraform/portainer-root/|\.github/workflows/|\.github/scripts/|\.github/ci/)' <<<"${changed_files}"; then
    run_portainer_apply="true"
  fi
}

run_infra_apply="false"
run_ansible_bootstrap="false"
run_portainer_apply="false"
stacks_sha=""
changed_stacks=""
config_stacks=""
structural_change="false"
reason=""
changed_paths=""

if [[ "${EVENT_NAME}" == "push" ]]; then
  before="${PUSH_BEFORE:-}"
  after="${PUSH_SHA:-${GITHUB_SHA:-HEAD}}"

  if [[ "${before}" =~ ^0+$ || -z "${before}" ]]; then
    changed_files="$(git show --name-only --pretty='' "${after}" || true)"
  else
    changed_files="$(git diff --name-only "${before}" "${after}" || true)"
  fi

  changed_paths="$(normalize_csv "$(echo "${changed_files}" | paste -sd, -)")"

  if [[ "$(to_bool "${META_FILTER_APPLIED:-false}")" == "true" ]]; then
    run_infra_apply="$(to_bool "${META_INFRA_CHANGED:-false}")"
    run_ansible_bootstrap="$(to_bool "${META_ANSIBLE_CHANGED:-false}")"
    run_portainer_apply="$(to_bool "${META_PORTAINER_CHANGED:-false}")"
  else
    derive_push_flags_from_changed_files "${changed_files}"
  fi

  # Infra changes imply Ansible bootstrap and Portainer apply sequencing.
  if [[ "${run_infra_apply}" == "true" ]]; then
    run_ansible_bootstrap="true"
    run_portainer_apply="true"
  fi

  # Ansible/bootstrap-related changes should reconcile Portainer credentials.
  if [[ "${run_ansible_bootstrap}" == "true" ]]; then
    run_portainer_apply="true"
  fi

  reason="infra-repo-push"
elif [[ "${EVENT_NAME}" == "repository_dispatch" ]]; then
  stacks_sha="$(normalize_nullable "${PAYLOAD_STACKS_SHA:-}")"
  changed_stacks="$(normalize_csv "${PAYLOAD_CHANGED_STACKS:-}")"
  config_stacks="$(normalize_csv "${PAYLOAD_CONFIG_STACKS:-}")"
  structural_change="$(to_bool "${PAYLOAD_STRUCTURAL_CHANGE:-}")"
  reason="$(normalize_nullable "${PAYLOAD_REASON:-}")"
  changed_paths="$(normalize_csv "${PAYLOAD_CHANGED_PATHS:-}")"

  if [[ "${structural_change}" == "true" || "${reason}" == "structural-change" || "${reason}" == "manual-refresh" ]]; then
    run_portainer_apply="true"
  fi
elif [[ "${EVENT_NAME}" == "workflow_dispatch" || "${EVENT_NAME}" == "workflow_call" ]]; then
  run_infra_apply="$(to_bool "${INPUT_RUN_INFRA:-}")"
  run_ansible_bootstrap="$(to_bool "${INPUT_RUN_ANSIBLE:-}")"
  run_portainer_apply="$(to_bool "${INPUT_RUN_PORTAINER:-}")"
  stacks_sha="$(normalize_nullable "${INPUT_STACKS_SHA:-}")"
  changed_stacks="$(normalize_csv "${INPUT_CHANGED_STACKS:-}")"
  config_stacks="$(normalize_csv "${INPUT_CONFIG_STACKS:-}")"
  structural_change="$(to_bool "${INPUT_STRUCTURAL_CHANGE:-}")"
  reason="$(normalize_nullable "${INPUT_REASON:-}")"
  changed_paths="$(normalize_csv "${INPUT_CHANGED_PATHS:-}")"
fi

if [[ -n "${config_stacks}" ]]; then
  changed_stacks="$(normalize_csv "${changed_stacks},${config_stacks}")"
fi

run_config_sync="false"
if [[ -n "${config_stacks}" ]]; then
  run_config_sync="true"
fi

run_health_redeploy="false"
if [[ -n "${changed_stacks}" ]]; then
  run_health_redeploy="true"
fi

if [[ -z "${reason}" ]]; then
  if [[ "${run_infra_apply}" == "true" ]]; then
    reason="infra-reconcile"
  elif [[ "${run_portainer_apply}" == "true" ]]; then
    reason="portainer-reconcile"
  elif [[ "${run_health_redeploy}" == "true" ]]; then
    reason="content-change"
  else
    reason="no-op"
  fi
fi

if [[ "$(to_bool "${RESOLVE_STACKS_SHA_FROM_HEAD:-false}")" == "true" && -z "${stacks_sha}" ]]; then
  stacks_sha="$(git rev-parse HEAD:stacks 2>/dev/null || true)"
fi

if [[ -n "${stacks_sha}" && ! "${stacks_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid stacks SHA: ${stacks_sha}"
  exit 1
fi

has_work="false"
if [[ "${run_infra_apply}" == "true" || "${run_ansible_bootstrap}" == "true" || "${run_portainer_apply}" == "true" || "${run_config_sync}" == "true" || "${run_health_redeploy}" == "true" ]]; then
  has_work="true"
fi

echo "run_infra_apply=${run_infra_apply}" >> "${GITHUB_OUTPUT}"
echo "run_ansible_bootstrap=${run_ansible_bootstrap}" >> "${GITHUB_OUTPUT}"
echo "run_portainer_apply=${run_portainer_apply}" >> "${GITHUB_OUTPUT}"
echo "run_config_sync=${run_config_sync}" >> "${GITHUB_OUTPUT}"
echo "run_health_redeploy=${run_health_redeploy}" >> "${GITHUB_OUTPUT}"
echo "has_work=${has_work}" >> "${GITHUB_OUTPUT}"
echo "stacks_sha=${stacks_sha}" >> "${GITHUB_OUTPUT}"
echo "changed_stacks=${changed_stacks}" >> "${GITHUB_OUTPUT}"
echo "config_stacks=${config_stacks}" >> "${GITHUB_OUTPUT}"
echo "structural_change=${structural_change}" >> "${GITHUB_OUTPUT}"
echo "reason=${reason}" >> "${GITHUB_OUTPUT}"
echo "changed_paths=${changed_paths}" >> "${GITHUB_OUTPUT}"
