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
  "event_name": "workflow_dispatch",
  "meta": {
    "run_infra_apply": true,
    "run_ansible_bootstrap": true,
    "run_portainer_apply": true,
    "run_config_sync": true,
    "run_health_redeploy": false,
    "has_work": true,
    "stacks_sha": "0123456789abcdef0123456789abcdef01234567",
    "changed_stacks": "auth,gateway",
    "config_stacks": "auth",
    "structural_change": false,
    "reason": "manual-dispatch",
    "changed_paths": "stacks.yaml",
    "stages": {
      "stage_cloud_runner_guard": true,
      "stage_secret_validation": true,
      "stage_network_policy_sync": true,
      "stage_infra_apply": true,
      "stage_inventory_handover": true,
      "stage_network_preflight_ssh": true,
      "stage_ansible_bootstrap": true,
      "stage_post_bootstrap_secret_check": true,
      "stage_portainer_api_preflight": true,
      "stage_portainer_apply": true,
      "stage_config_sync": true,
      "stage_health_gated_redeploy": false
    }
  }
}
JSON
)"

iac_plan_json="$(cat <<'JSON'
{
  "plan_schema_version": "ci-plan-v1",
  "mode": "iac",
  "event_name": "pull_request",
  "iac": {
    "infra_workspace_changed": true,
    "portainer_workspace_changed": false,
    "ansible_changed": true,
    "stacks_gitlink_changed": true,
    "stacks_sha": "fedcba9876543210fedcba9876543210fedcba98",
    "changed_tf_roots": ["terraform/infra", "terraform/oci"],
    "tfc_workspace_matrix": [{"workspace_key":"infra","config_directory":"terraform/infra"}]
  }
}
JSON
)"

meta_out="$(run_case "meta_projection" "meta" "${meta_plan_json}")"
assert_eq "meta_projection" "run_infra_apply" "true" "$(read_output "${meta_out}" "run_infra_apply")"
assert_eq "meta_projection" "run_config_sync" "true" "$(read_output "${meta_out}" "run_config_sync")"
assert_eq "meta_projection" "changed_stacks" "auth,gateway" "$(read_output "${meta_out}" "changed_stacks")"
assert_eq "meta_projection" "stage_portainer_apply" "true" "$(read_output "${meta_out}" "stage_portainer_apply")"
assert_eq "meta_projection" "stage_health_gated_redeploy" "false" "$(read_output "${meta_out}" "stage_health_gated_redeploy")"

iac_out="$(run_case "iac_projection" "iac" "${iac_plan_json}")"
assert_eq "iac_projection" "infra_workspace_changed" "true" "$(read_output "${iac_out}" "infra_workspace_changed")"
assert_eq "iac_projection" "ansible_changed" "true" "$(read_output "${iac_out}" "ansible_changed")"
assert_eq "iac_projection" "stacks_sha" "fedcba9876543210fedcba9876543210fedcba98" "$(read_output "${iac_out}" "stacks_sha")"
assert_eq "iac_projection" "changed_tf_roots_json" '["terraform/infra","terraform/oci"]' "$(read_output "${iac_out}" "changed_tf_roots_json")"
assert_eq "iac_projection" "tfc_workspace_matrix_json" '[{"workspace_key":"infra","config_directory":"terraform/infra"}]' "$(read_output "${iac_out}" "tfc_workspace_matrix_json")"

invalid_schema_json="$(jq -c '.plan_schema_version = "ci-plan-v0"' <<<"${meta_plan_json}")"
run_case_expect_fail "invalid_schema_version" "meta" "${invalid_schema_json}"

run_case_expect_fail "mode_mismatch" "iac" "${meta_plan_json}"

missing_field_json="$(jq -c 'del(.meta.stages.stage_portainer_apply)' <<<"${meta_plan_json}")"
run_case_expect_fail "missing_required_field" "meta" "${missing_field_json}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
