#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/plan/project_plan_outputs.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found; install jq to run project_plan_outputs tests."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

read_output() {
  local file="$1"
  local key="$2"
  local value
  value="$(grep -E "^${key}=" "${file}" | tail -n1 | cut -d= -f2- || true)"
  echo "${value}"
}

pass() {
  local message="$1"
  echo "[PASS] ${message}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local message="$1"
  echo "[FAIL] ${message}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  local case_name="$1"
  local key="$2"
  local expected="$3"
  local actual="$4"

  if [[ "${expected}" == "${actual}" ]]; then
    pass "${case_name}: ${key}=${expected}"
  else
    fail "${case_name}: ${key} expected='${expected}' actual='${actual}'"
  fi
}

run_case() {
  local case_name="$1"
  local mode="$2"
  local plan_json="$3"
  local out_file="${TMP_DIR}/${case_name}.out"

  (
    set -euo pipefail
    export PLAN_JSON="${plan_json}"
    export GITHUB_OUTPUT="${out_file}"
    "${SCRIPT}" "${mode}"
  )

  echo "${out_file}"
}

run_case_expect_fail() {
  local case_name="$1"
  local mode="$2"
  local plan_json="$3"
  local out_file="${TMP_DIR}/${case_name}.out"

  if (
    set -euo pipefail
    export PLAN_JSON="${plan_json}"
    export GITHUB_OUTPUT="${out_file}"
    "${SCRIPT}" "${mode}"
  ); then
    fail "${case_name}: expected failure but script succeeded"
  else
    pass "${case_name}: failed as expected"
  fi
}

meta_plan_json="$(cat <<'JSON'
{
  "plan_schema_version": "ci-plan-v1",
  "mode": "meta",
  "event_name": "repository_dispatch",
  "meta": {
    "run_infra_apply": false,
    "run_ansible_bootstrap": false,
    "run_portainer_apply": true,
    "run_host_sync": true,
    "run_config_sync": true,
    "run_health_redeploy": true,
    "has_work": true,
    "stacks_sha": "0123456789abcdef0123456789abcdef01234567",
    "reason": "full-reconcile",
    "stages": {
      "stage_cloud_runner_guard": true,
      "stage_secret_validation": true,
      "stage_network_policy_sync": true,
      "stage_infra_apply": false,
      "stage_inventory_handover": true,
      "stage_network_preflight_ssh": true,
      "stage_ansible_bootstrap": false,
      "stage_host_sync": true,
      "stage_post_bootstrap_secret_check": true,
      "stage_portainer_api_preflight": true,
      "stage_portainer_apply": true,
      "stage_config_sync": true,
      "stage_health_gated_redeploy": true
    }
  }
}
JSON
)"

meta_out="$(run_case "meta_projection" "meta" "${meta_plan_json}")"
assert_eq "meta_projection" "run_portainer_apply" "true" "$(read_output "${meta_out}" "run_portainer_apply")"
assert_eq "meta_projection" "run_host_sync" "true" "$(read_output "${meta_out}" "run_host_sync")"
assert_eq "meta_projection" "run_config_sync" "true" "$(read_output "${meta_out}" "run_config_sync")"
assert_eq "meta_projection" "run_health_redeploy" "true" "$(read_output "${meta_out}" "run_health_redeploy")"
assert_eq "meta_projection" "stacks_sha" "0123456789abcdef0123456789abcdef01234567" "$(read_output "${meta_out}" "stacks_sha")"
assert_eq "meta_projection" "reason" "full-reconcile" "$(read_output "${meta_out}" "reason")"
assert_eq "meta_projection" "stage_host_sync" "true" "$(read_output "${meta_out}" "stage_host_sync")"
assert_eq "meta_projection" "stage_health_gated_redeploy" "true" "$(read_output "${meta_out}" "stage_health_gated_redeploy")"

invalid_schema_json="$(jq -c '.plan_schema_version = "ci-plan-v0"' <<<"${meta_plan_json}")"
run_case_expect_fail "invalid_schema_version" "meta" "${invalid_schema_json}"

run_case_expect_fail "unsupported_mode" "iac" "${meta_plan_json}"

missing_field_json="$(jq -c 'del(.meta.reason)' <<<"${meta_plan_json}")"
run_case_expect_fail "missing_required_field" "meta" "${missing_field_json}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
