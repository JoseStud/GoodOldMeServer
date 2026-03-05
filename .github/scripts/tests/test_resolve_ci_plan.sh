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
  )

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
  ); then
    fail "${case_name}: expected failure but script succeeded"
  else
    pass "${case_name}: failed as expected"
  fi
}

write_env_file() {
  local file="$1"
  shift
  : > "${file}"
  while [[ $# -gt 0 ]]; do
    echo "export $1" >> "${file}"
    shift
  done
}

# Case 1: meta push infra filter -> infra implies ansible+portainer
case1_env="${TMP_DIR}/case1.env"
write_env_file "${case1_env}" \
  "PUSH_BEFORE=${HEAD_SHA}" \
  "PUSH_SHA=${HEAD_SHA}" \
  "META_FILTER_APPLIED=true" \
  "META_INFRA_CHANGED=true" \
  "META_ANSIBLE_CHANGED=false" \
  "META_PORTAINER_CHANGED=false"
case1_out="$(run_plan_case "meta_push_infra_filter" "meta" "push" "${case1_env}")"
assert_eq "meta_push_infra_filter" "run_infra_apply" "true" "$(read_output "${case1_out}" "run_infra_apply")"
assert_eq "meta_push_infra_filter" "run_ansible_bootstrap" "true" "$(read_output "${case1_out}" "run_ansible_bootstrap")"
assert_eq "meta_push_infra_filter" "run_portainer_apply" "true" "$(read_output "${case1_out}" "run_portainer_apply")"
assert_eq "meta_push_infra_filter" "run_health_redeploy" "false" "$(read_output "${case1_out}" "run_health_redeploy")"

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
assert_eq "meta_push_ansible_filter" "run_infra_apply" "false" "$(read_output "${case2_out}" "run_infra_apply")"
assert_eq "meta_push_ansible_filter" "run_ansible_bootstrap" "true" "$(read_output "${case2_out}" "run_ansible_bootstrap")"
assert_eq "meta_push_ansible_filter" "run_portainer_apply" "true" "$(read_output "${case2_out}" "run_portainer_apply")"

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
assert_eq "meta_push_portainer_filter" "run_infra_apply" "false" "$(read_output "${case3_out}" "run_infra_apply")"
assert_eq "meta_push_portainer_filter" "run_ansible_bootstrap" "false" "$(read_output "${case3_out}" "run_ansible_bootstrap")"
assert_eq "meta_push_portainer_filter" "run_portainer_apply" "true" "$(read_output "${case3_out}" "run_portainer_apply")"

# Case 4: meta repository_dispatch structural change
case4_env="${TMP_DIR}/case4.env"
write_env_file "${case4_env}" \
  "PAYLOAD_SCHEMA_VERSION=v3" \
  "PAYLOAD_STACKS_SHA=${HEAD_SHA}" \
  "PAYLOAD_SOURCE_SHA=${HEAD_SHA}" \
  "PAYLOAD_CHANGED_STACKS_JSON=[\"gateway\"]" \
  "PAYLOAD_CONFIG_STACKS_JSON=[]" \
  "PAYLOAD_STRUCTURAL_CHANGE=true" \
  "PAYLOAD_REASON=structural-change" \
  "PAYLOAD_CHANGED_PATHS_JSON=[\"stacks.yaml\"]" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
case4_out="$(run_plan_case "meta_repo_dispatch_structural" "meta" "repository_dispatch" "${case4_env}")"
assert_eq "meta_repo_dispatch_structural" "run_portainer_apply" "true" "$(read_output "${case4_out}" "run_portainer_apply")"
assert_eq "meta_repo_dispatch_structural" "run_health_redeploy" "true" "$(read_output "${case4_out}" "run_health_redeploy")"
assert_eq "meta_repo_dispatch_structural" "run_config_sync" "false" "$(read_output "${case4_out}" "run_config_sync")"

# Case 5: meta repository_dispatch config-only path
case5_env="${TMP_DIR}/case5.env"
write_env_file "${case5_env}" \
  "PAYLOAD_SCHEMA_VERSION=v3" \
  "PAYLOAD_STACKS_SHA=${HEAD_SHA}" \
  "PAYLOAD_SOURCE_SHA=${HEAD_SHA}" \
  "PAYLOAD_CHANGED_STACKS_JSON=[]" \
  "PAYLOAD_CONFIG_STACKS_JSON=[\"auth\"]" \
  "PAYLOAD_STRUCTURAL_CHANGE=false" \
  "PAYLOAD_REASON=content-change" \
  "PAYLOAD_CHANGED_PATHS_JSON=[\"auth/config/configuration.yml\"]" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
case5_out="$(run_plan_case "meta_repo_dispatch_config" "meta" "repository_dispatch" "${case5_env}")"
assert_eq "meta_repo_dispatch_config" "changed_stacks" "auth" "$(read_output "${case5_out}" "changed_stacks")"
assert_eq "meta_repo_dispatch_config" "run_config_sync" "true" "$(read_output "${case5_out}" "run_config_sync")"
assert_eq "meta_repo_dispatch_config" "run_health_redeploy" "true" "$(read_output "${case5_out}" "run_health_redeploy")"

# Case 6: meta repository_dispatch no-op
case6_env="${TMP_DIR}/case6.env"
write_env_file "${case6_env}" \
  "VALIDATE_DISPATCH_CONTRACT=false" \
  "PAYLOAD_STACKS_SHA=${HEAD_SHA}" \
  "PAYLOAD_CHANGED_STACKS_JSON=[]" \
  "PAYLOAD_CONFIG_STACKS_JSON=[]" \
  "PAYLOAD_STRUCTURAL_CHANGE=false" \
  "PAYLOAD_REASON=no-op" \
  "PAYLOAD_CHANGED_PATHS_JSON=[]"
case6_out="$(run_plan_case "meta_repo_dispatch_noop" "meta" "repository_dispatch" "${case6_env}")"
assert_eq "meta_repo_dispatch_noop" "has_work" "false" "$(read_output "${case6_out}" "has_work")"
assert_eq "meta_repo_dispatch_noop" "run_health_redeploy" "false" "$(read_output "${case6_out}" "run_health_redeploy")"

# Case 7: meta workflow_dispatch infra only
case7_env="${TMP_DIR}/case7.env"
write_env_file "${case7_env}" \
  "INPUT_RUN_INFRA=true" \
  "INPUT_RUN_ANSIBLE=false" \
  "INPUT_RUN_PORTAINER=false" \
  "INPUT_STACKS_SHA=" \
  "INPUT_CHANGED_STACKS_JSON=[]" \
  "INPUT_CONFIG_STACKS_JSON=[]" \
  "INPUT_STRUCTURAL_CHANGE=false" \
  "INPUT_REASON=manual-dispatch" \
  "INPUT_CHANGED_PATHS_JSON=[]"
case7_out="$(run_plan_case "meta_manual_infra_only" "meta" "workflow_dispatch" "${case7_env}")"
assert_eq "meta_manual_infra_only" "run_infra_apply" "true" "$(read_output "${case7_out}" "run_infra_apply")"
assert_eq "meta_manual_infra_only" "run_ansible_bootstrap" "false" "$(read_output "${case7_out}" "run_ansible_bootstrap")"
assert_eq "meta_manual_infra_only" "run_portainer_apply" "false" "$(read_output "${case7_out}" "run_portainer_apply")"

# Case 8: meta workflow_dispatch stacks config+content
case8_env="${TMP_DIR}/case8.env"
write_env_file "${case8_env}" \
  "INPUT_RUN_INFRA=false" \
  "INPUT_RUN_ANSIBLE=false" \
  "INPUT_RUN_PORTAINER=false" \
  "INPUT_STACKS_SHA=${HEAD_SHA}" \
  "INPUT_CHANGED_STACKS_JSON=[\"gateway\"]" \
  "INPUT_CONFIG_STACKS_JSON=[\"auth\"]" \
  "INPUT_STRUCTURAL_CHANGE=false" \
  "INPUT_REASON=manual-dispatch" \
  "INPUT_CHANGED_PATHS_JSON=[\"auth/config/configuration.yml\"]"
case8_out="$(run_plan_case "meta_manual_stack_paths" "meta" "workflow_dispatch" "${case8_env}")"
assert_eq "meta_manual_stack_paths" "changed_stacks" "auth,gateway" "$(read_output "${case8_out}" "changed_stacks")"
assert_eq "meta_manual_stack_paths" "run_config_sync" "true" "$(read_output "${case8_out}" "run_config_sync")"
assert_eq "meta_manual_stack_paths" "run_health_redeploy" "true" "$(read_output "${case8_out}" "run_health_redeploy")"

# Case 9: meta invalid stacks SHA should fail
case9_env="${TMP_DIR}/case9.env"
write_env_file "${case9_env}" \
  "INPUT_RUN_INFRA=false" \
  "INPUT_RUN_ANSIBLE=false" \
  "INPUT_RUN_PORTAINER=false" \
  "INPUT_STACKS_SHA=bad_sha" \
  "INPUT_REASON=manual-dispatch"
run_plan_case_expect_fail "meta_invalid_stacks_sha" "meta" "workflow_dispatch" "${case9_env}"

# Case 9b: meta invalid JSON stack list should fail
case9b_env="${TMP_DIR}/case9b.env"
write_env_file "${case9b_env}" \
  "INPUT_RUN_INFRA=false" \
  "INPUT_RUN_ANSIBLE=false" \
  "INPUT_RUN_PORTAINER=false" \
  "INPUT_STACKS_SHA=${HEAD_SHA}" \
  "INPUT_CHANGED_STACKS_JSON=[\"bad,stack\"]" \
  "INPUT_CONFIG_STACKS_JSON=[]" \
  "INPUT_REASON=manual-dispatch"
run_plan_case_expect_fail "meta_invalid_stack_json" "meta" "workflow_dispatch" "${case9b_env}"

# Case 10: iac workflow_dispatch should enable all checks
case10_env="${TMP_DIR}/case10.env"
write_env_file "${case10_env}" \
  "GITHUB_SHA_CURRENT=${HEAD_SHA}"
case10_out="$(run_plan_case "iac_dispatch_all" "iac" "workflow_dispatch" "${case10_env}")"
assert_eq "iac_dispatch_all" "infra_workspace_changed" "true" "$(read_output "${case10_out}" "infra_workspace_changed")"
assert_eq "iac_dispatch_all" "portainer_workspace_changed" "true" "$(read_output "${case10_out}" "portainer_workspace_changed")"
assert_eq "iac_dispatch_all" "ansible_changed" "true" "$(read_output "${case10_out}" "ansible_changed")"
assert_eq "iac_dispatch_all" "stacks_gitlink_changed" "true" "$(read_output "${case10_out}" "stacks_gitlink_changed")"
assert_eq "iac_dispatch_all" "changed_tf_roots_json" '["terraform/infra","terraform/oci","terraform/gcp","terraform/portainer-root","terraform/portainer"]' "$(read_output "${case10_out}" "changed_tf_roots_json")"

# Case 11: iac pull_request filter booleans
case11_env="${TMP_DIR}/case11.env"
write_env_file "${case11_env}" \
  "GITHUB_SHA_CURRENT=${HEAD_SHA}" \
  "IAC_WORKSPACE_INFRA=true" \
  "IAC_WORKSPACE_PORTAINER=false" \
  "IAC_ANSIBLE=true" \
  "IAC_STACKS_GITLINK_CHANGED=false" \
  "IAC_TF_INFRA=true" \
  "IAC_TF_OCI=true" \
  "IAC_TF_GCP=false" \
  "IAC_TF_PORTAINER_ROOT=false" \
  "IAC_TF_PORTAINER=false"
case11_out="$(run_plan_case "iac_pr_flags" "iac" "pull_request" "${case11_env}")"
assert_eq "iac_pr_flags" "infra_workspace_changed" "true" "$(read_output "${case11_out}" "infra_workspace_changed")"
assert_eq "iac_pr_flags" "ansible_changed" "true" "$(read_output "${case11_out}" "ansible_changed")"
assert_eq "iac_pr_flags" "changed_tf_roots_json" '["terraform/infra","terraform/oci"]' "$(read_output "${case11_out}" "changed_tf_roots_json")"
assert_eq "iac_pr_flags" "tfc_workspace_matrix_json" '[{"workspace_key":"infra","config_directory":"terraform/infra"}]' "$(read_output "${case11_out}" "tfc_workspace_matrix_json")"

# Case 12: iac push path-filter mode with stacks gitlink
case12_env="${TMP_DIR}/case12.env"
write_env_file "${case12_env}" \
  "GITHUB_SHA_CURRENT=${HEAD_SHA}" \
  "PUSH_BEFORE_SHA=${HEAD_SHA}" \
  "IAC_WORKSPACE_INFRA=false" \
  "IAC_WORKSPACE_PORTAINER=true" \
  "IAC_ANSIBLE=false" \
  "IAC_STACKS_GITLINK_CHANGED=true" \
  "IAC_TF_INFRA=false" \
  "IAC_TF_OCI=false" \
  "IAC_TF_GCP=false" \
  "IAC_TF_PORTAINER_ROOT=true" \
  "IAC_TF_PORTAINER=true"
case12_out="$(run_plan_case "iac_push_portainer_gitlink" "iac" "push" "${case12_env}")"
assert_eq "iac_push_portainer_gitlink" "portainer_workspace_changed" "true" "$(read_output "${case12_out}" "portainer_workspace_changed")"
assert_eq "iac_push_portainer_gitlink" "stacks_gitlink_changed" "true" "$(read_output "${case12_out}" "stacks_gitlink_changed")"
assert_eq "iac_push_portainer_gitlink" "changed_tf_roots_json" '["terraform/portainer-root","terraform/portainer"]' "$(read_output "${case12_out}" "changed_tf_roots_json")"
assert_eq "iac_push_portainer_gitlink" "stacks_sha" "${HEAD_SHA}" "$(read_output "${case12_out}" "stacks_sha")"
assert_eq "iac_push_portainer_gitlink" "tfc_workspace_matrix_json" '[]' "$(read_output "${case12_out}" "tfc_workspace_matrix_json")"

# Additional validator failure check for non-v3 dispatch schema
if (
  export EVENT_NAME="repository_dispatch"
  export PAYLOAD_SCHEMA_VERSION="v1"
  export PAYLOAD_STACKS_SHA="${HEAD_SHA}"
  export PAYLOAD_SOURCE_SHA="${HEAD_SHA}"
  export PAYLOAD_CHANGED_STACKS_JSON="[\"gateway\"]"
  export PAYLOAD_CONFIG_STACKS_JSON="[]"
  export PAYLOAD_STRUCTURAL_CHANGE="false"
  export PAYLOAD_REASON="content-change"
  export PAYLOAD_CHANGED_PATHS_JSON="[\"gateway/docker-compose.yml\"]"
  export PAYLOAD_SOURCE_REPO="example/stacks"
  export PAYLOAD_SOURCE_RUN_ID="12345"
  "${VALIDATOR}" meta
); then
  fail "dispatch_validator_v3_enforced: expected failure for schema v1"
else
  pass "dispatch_validator_v3_enforced"
fi

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
