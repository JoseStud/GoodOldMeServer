#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/plan/resolve_ci_plan.sh"
VALIDATOR="${ROOT_DIR}/.github/scripts/plan/validate_dispatch_payload.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found; install jq to run resolve_ci_plan fixture tests."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
HEAD_SHA="$(git -C "${ROOT_DIR}" rev-parse HEAD)"

read_output() {
  local file="$1"
  local key="$2"
  local value
  value="$(grep -E "^${key}=" "${file}" | tail -n1 | cut -d= -f2- || true)"
  echo "${value}"
}

read_plan_json_field() {
  local file="$1"
  local jq_expr="$2"
  local plan_json
  plan_json="$(read_output "${file}" "plan_json")"
  jq -r "${jq_expr}" <<<"${plan_json}"
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

run_plan_case() {
  local case_name="$1"
  local mode="$2"
  local event_name="$3"
  local env_file="$4"
  local out_file="${TMP_DIR}/${case_name}.out"

  (
    set -euo pipefail
    source "${env_file}"
    export GITHUB_OUTPUT="${out_file}"
    export CI_PLAN_MODE="${mode}"
    export EVENT_NAME="${event_name}"
    "${SCRIPT}"
  ) >&2

  echo "${out_file}"
}

run_plan_case_expect_fail() {
  local case_name="$1"
  local mode="$2"
  local event_name="$3"
  local env_file="$4"

  if (
    set -euo pipefail
    source "${env_file}"
    export GITHUB_OUTPUT="${TMP_DIR}/${case_name}.out"
    export CI_PLAN_MODE="${mode}"
    export EVENT_NAME="${event_name}"
    "${SCRIPT}"
  ) >&2 2>&1; then
    fail "${case_name}: expected failure but script succeeded"
  else
    pass "${case_name}: failed as expected"
  fi
}

run_validator_expect_fail() {
  local case_name="$1"
  local env_file="$2"

  if (
    set -euo pipefail
    source "${env_file}"
    "${VALIDATOR}" meta
  ) >&2 2>&1; then
    fail "${case_name}: expected failure but validator succeeded"
  else
    pass "${case_name}: failed as expected"
  fi
}

write_env_file() {
  local file="$1"
  shift
  : > "${file}"
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local value="${1#*=}"
    printf 'export %s=%q\n' "${key}" "${value}" >> "${file}"
    shift
  done
}

dispatch_payload_json="$(
  jq -cn \
    --arg stacks_sha "${HEAD_SHA}" \
    --arg source_sha "${HEAD_SHA}" \
    --arg source_repo "example/stacks" \
    --argjson source_run_id 12345 \
    '{
      schema_version: "v5",
      stacks_sha: $stacks_sha,
      source_sha: $source_sha,
      source_repo: $source_repo,
      source_run_id: $source_run_id,
      reason: "full-reconcile"
    }'
)"

# Case 1: meta push infra filter -> infra implies ansible + portainer
case1_env="${TMP_DIR}/case1.env"
write_env_file "${case1_env}" \
  "PUSH_BEFORE=${HEAD_SHA}" \
  "PUSH_SHA=${HEAD_SHA}" \
  "META_FILTER_APPLIED=true" \
  "META_INFRA_CHANGED=true" \
  "META_ANSIBLE_CHANGED=false" \
  "META_PORTAINER_CHANGED=false"
case1_out="$(run_plan_case "meta_push_infra_filter" "meta" "push" "${case1_env}")"
assert_eq "meta_push_infra_filter" "run_infra_apply" "true" "$(read_plan_json_field "${case1_out}" '.meta.run_infra_apply')"
assert_eq "meta_push_infra_filter" "run_ansible_bootstrap" "true" "$(read_plan_json_field "${case1_out}" '.meta.run_ansible_bootstrap')"
assert_eq "meta_push_infra_filter" "run_portainer_apply" "true" "$(read_plan_json_field "${case1_out}" '.meta.run_portainer_apply')"
assert_eq "meta_push_infra_filter" "run_health_redeploy" "false" "$(read_plan_json_field "${case1_out}" '.meta.run_health_redeploy')"
assert_eq "meta_push_infra_filter" "plan_schema_version" "ci-plan-v1" "$(read_plan_json_field "${case1_out}" '.plan_schema_version')"

# Case 2: meta push ansible filter -> ansible implies portainer
case2_env="${TMP_DIR}/case2.env"
write_env_file "${case2_env}" \
  "PUSH_BEFORE=${HEAD_SHA}" \
  "PUSH_SHA=${HEAD_SHA}" \
  "META_FILTER_APPLIED=true" \
  "META_INFRA_CHANGED=false" \
  "META_ANSIBLE_CHANGED=true" \
  "META_PORTAINER_CHANGED=false"
case2_out="$(run_plan_case "meta_push_ansible_filter" "meta" "push" "${case2_env}")"
assert_eq "meta_push_ansible_filter" "run_infra_apply" "false" "$(read_plan_json_field "${case2_out}" '.meta.run_infra_apply')"
assert_eq "meta_push_ansible_filter" "run_ansible_bootstrap" "true" "$(read_plan_json_field "${case2_out}" '.meta.run_ansible_bootstrap')"
assert_eq "meta_push_ansible_filter" "run_portainer_apply" "true" "$(read_plan_json_field "${case2_out}" '.meta.run_portainer_apply')"

# Case 3: meta push portainer-only filter
case3_env="${TMP_DIR}/case3.env"
write_env_file "${case3_env}" \
  "PUSH_BEFORE=${HEAD_SHA}" \
  "PUSH_SHA=${HEAD_SHA}" \
  "META_FILTER_APPLIED=true" \
  "META_INFRA_CHANGED=false" \
  "META_ANSIBLE_CHANGED=false" \
  "META_PORTAINER_CHANGED=true"
case3_out="$(run_plan_case "meta_push_portainer_filter" "meta" "push" "${case3_env}")"
assert_eq "meta_push_portainer_filter" "run_infra_apply" "false" "$(read_plan_json_field "${case3_out}" '.meta.run_infra_apply')"
assert_eq "meta_push_portainer_filter" "run_ansible_bootstrap" "false" "$(read_plan_json_field "${case3_out}" '.meta.run_ansible_bootstrap')"
assert_eq "meta_push_portainer_filter" "run_portainer_apply" "true" "$(read_plan_json_field "${case3_out}" '.meta.run_portainer_apply')"

# Case 4: repository_dispatch v5 always runs full reconcile
case4_env="${TMP_DIR}/case4.env"
write_env_file "${case4_env}" \
  "PAYLOAD_JSON=${dispatch_payload_json}" \
  "PAYLOAD_SCHEMA_VERSION=v5" \
  "PAYLOAD_STACKS_SHA=${HEAD_SHA}" \
  "PAYLOAD_SOURCE_SHA=${HEAD_SHA}" \
  "PAYLOAD_REASON=full-reconcile" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
case4_out="$(run_plan_case "meta_repo_dispatch_full_reconcile" "meta" "repository_dispatch" "${case4_env}")"
assert_eq "meta_repo_dispatch_full_reconcile" "run_portainer_apply" "true" "$(read_plan_json_field "${case4_out}" '.meta.run_portainer_apply')"
assert_eq "meta_repo_dispatch_full_reconcile" "run_host_sync" "true" "$(read_plan_json_field "${case4_out}" '.meta.run_host_sync')"
assert_eq "meta_repo_dispatch_full_reconcile" "run_config_sync" "true" "$(read_plan_json_field "${case4_out}" '.meta.run_config_sync')"
assert_eq "meta_repo_dispatch_full_reconcile" "run_health_redeploy" "true" "$(read_plan_json_field "${case4_out}" '.meta.run_health_redeploy')"
assert_eq "meta_repo_dispatch_full_reconcile" "reason" "full-reconcile" "$(read_plan_json_field "${case4_out}" '.meta.reason')"
assert_eq "meta_repo_dispatch_full_reconcile" "stacks_sha" "${HEAD_SHA}" "$(read_plan_json_field "${case4_out}" '.meta.stacks_sha')"

# Case 5: workflow_dispatch is no longer supported for meta mode
case5_env="${TMP_DIR}/case5.env"
write_env_file "${case5_env}"
run_plan_case_expect_fail "meta_workflow_dispatch_removed" "meta" "workflow_dispatch" "${case5_env}"

# Case 6: iac mode is retired
case6_env="${TMP_DIR}/case6.env"
write_env_file "${case6_env}"
run_plan_case_expect_fail "iac_mode_removed" "iac" "push" "${case6_env}"

# Case 7: validator rejects legacy v4 schema
case7_env="${TMP_DIR}/case7.env"
legacy_payload_json="$(jq -c '.schema_version = "v4"' <<<"${dispatch_payload_json}")"
write_env_file "${case7_env}" \
  "EVENT_NAME=repository_dispatch" \
  "PAYLOAD_JSON=${legacy_payload_json}" \
  "PAYLOAD_SCHEMA_VERSION=v4" \
  "PAYLOAD_STACKS_SHA=${HEAD_SHA}" \
  "PAYLOAD_SOURCE_SHA=${HEAD_SHA}" \
  "PAYLOAD_REASON=full-reconcile" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
run_validator_expect_fail "dispatch_validator_v4_rejected" "${case7_env}"

# Case 8: validator rejects wrong reason
case8_env="${TMP_DIR}/case8.env"
wrong_reason_payload_json="$(jq -c '.reason = "manual-refresh"' <<<"${dispatch_payload_json}")"
write_env_file "${case8_env}" \
  "EVENT_NAME=repository_dispatch" \
  "PAYLOAD_JSON=${wrong_reason_payload_json}" \
  "PAYLOAD_SCHEMA_VERSION=v5" \
  "PAYLOAD_STACKS_SHA=${HEAD_SHA}" \
  "PAYLOAD_SOURCE_SHA=${HEAD_SHA}" \
  "PAYLOAD_REASON=manual-refresh" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
run_validator_expect_fail "dispatch_validator_reason_rejected" "${case8_env}"

# Case 9: validator rejects removed selective fields
case9_env="${TMP_DIR}/case9.env"
removed_field_payload_json="$(jq -c '.changed_stacks = ["gateway"]' <<<"${dispatch_payload_json}")"
write_env_file "${case9_env}" \
  "EVENT_NAME=repository_dispatch" \
  "PAYLOAD_JSON=${removed_field_payload_json}" \
  "PAYLOAD_SCHEMA_VERSION=v5" \
  "PAYLOAD_STACKS_SHA=${HEAD_SHA}" \
  "PAYLOAD_SOURCE_SHA=${HEAD_SHA}" \
  "PAYLOAD_REASON=full-reconcile" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
run_validator_expect_fail "dispatch_validator_removed_field_rejected" "${case9_env}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
