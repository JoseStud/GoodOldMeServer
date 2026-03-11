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
STACKS_SHA="$(git -C "${ROOT_DIR}" rev-parse HEAD:stacks)"

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

# Like run_plan_case but changes into a specific directory first, allowing git
# commands inside the scripts to operate against a controlled repo.
run_plan_case_in_dir() {
  local case_name="$1"
  local mode="$2"
  local event_name="$3"
  local env_file="$4"
  local repo_dir="$5"
  local out_file="${TMP_DIR}/${case_name}.out"

  (
    set -euo pipefail
    cd "${repo_dir}"
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
    --arg stacks_sha "${STACKS_SHA}" \
    --arg source_sha "${STACKS_SHA}" \
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

# Case 1: infra-repo push always runs the full infra-side reconcile path
case1_env="${TMP_DIR}/case1.env"
write_env_file "${case1_env}" \
  "PUSH_BEFORE=${HEAD_SHA}" \
  "PUSH_SHA=${HEAD_SHA}"
case1_out="$(run_plan_case "meta_push_full_reconcile" "meta" "push" "${case1_env}")"
assert_eq "meta_push_full_reconcile" "run_infra_apply" "true" "$(read_plan_json_field "${case1_out}" '.meta.run_infra_apply')"
assert_eq "meta_push_full_reconcile" "run_ansible_bootstrap" "true" "$(read_plan_json_field "${case1_out}" '.meta.run_ansible_bootstrap')"
assert_eq "meta_push_full_reconcile" "run_portainer_apply" "true" "$(read_plan_json_field "${case1_out}" '.meta.run_portainer_apply')"
assert_eq "meta_push_full_reconcile" "run_health_redeploy" "false" "$(read_plan_json_field "${case1_out}" '.meta.run_health_redeploy')"
assert_eq "meta_push_full_reconcile" "stacks_sha" "${STACKS_SHA}" "$(read_plan_json_field "${case1_out}" '.meta.stacks_sha')"
assert_eq "meta_push_full_reconcile" "reason" "infra-repo-push" "$(read_plan_json_field "${case1_out}" '.meta.reason')"
assert_eq "meta_push_full_reconcile" "plan_schema_version" "ci-plan-v1" "$(read_plan_json_field "${case1_out}" '.plan_schema_version')"

# Case 2: repository_dispatch v5 always runs full reconcile
case2_env="${TMP_DIR}/case2.env"
write_env_file "${case2_env}" \
  "PAYLOAD_JSON=${dispatch_payload_json}" \
  "PAYLOAD_STACKS_SHA=${STACKS_SHA}" \
  "PAYLOAD_SOURCE_SHA=${STACKS_SHA}" \
  "PAYLOAD_REASON=full-reconcile" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
case2_out="$(run_plan_case "meta_repo_dispatch_full_reconcile" "meta" "repository_dispatch" "${case2_env}")"
assert_eq "meta_repo_dispatch_full_reconcile" "run_portainer_apply" "true" "$(read_plan_json_field "${case2_out}" '.meta.run_portainer_apply')"
assert_eq "meta_repo_dispatch_full_reconcile" "run_host_sync" "true" "$(read_plan_json_field "${case2_out}" '.meta.run_host_sync')"
assert_eq "meta_repo_dispatch_full_reconcile" "run_config_sync" "true" "$(read_plan_json_field "${case2_out}" '.meta.run_config_sync')"
assert_eq "meta_repo_dispatch_full_reconcile" "run_health_redeploy" "true" "$(read_plan_json_field "${case2_out}" '.meta.run_health_redeploy')"
assert_eq "meta_repo_dispatch_full_reconcile" "reason" "full-reconcile" "$(read_plan_json_field "${case2_out}" '.meta.reason')"
assert_eq "meta_repo_dispatch_full_reconcile" "stacks_sha" "${STACKS_SHA}" "$(read_plan_json_field "${case2_out}" '.meta.stacks_sha')"

# Case 3: workflow_dispatch runs full infra-side reconcile (reason=manual-dispatch)
case3_env="${TMP_DIR}/case3.env"
write_env_file "${case3_env}"
case3_out="$(run_plan_case "meta_workflow_dispatch_full_reconcile" "meta" "workflow_dispatch" "${case3_env}")"
assert_eq "meta_workflow_dispatch_full_reconcile" "run_infra_apply" "true" "$(read_plan_json_field "${case3_out}" '.meta.run_infra_apply')"
assert_eq "meta_workflow_dispatch_full_reconcile" "run_ansible_bootstrap" "true" "$(read_plan_json_field "${case3_out}" '.meta.run_ansible_bootstrap')"
assert_eq "meta_workflow_dispatch_full_reconcile" "run_portainer_apply" "true" "$(read_plan_json_field "${case3_out}" '.meta.run_portainer_apply')"
assert_eq "meta_workflow_dispatch_full_reconcile" "run_health_redeploy" "false" "$(read_plan_json_field "${case3_out}" '.meta.run_health_redeploy')"
assert_eq "meta_workflow_dispatch_full_reconcile" "stacks_sha" "${STACKS_SHA}" "$(read_plan_json_field "${case3_out}" '.meta.stacks_sha')"
assert_eq "meta_workflow_dispatch_full_reconcile" "reason" "manual-dispatch" "$(read_plan_json_field "${case3_out}" '.meta.reason')"

# Case 4a: push_ansible_only skips infra apply, runs bootstrap + portainer
case4a_env="${TMP_DIR}/case4a.env"
write_env_file "${case4a_env}" \
  "PUSH_BEFORE=${HEAD_SHA}" \
  "PUSH_SHA=${HEAD_SHA}"
case4a_out="$(run_plan_case "meta_push_ansible_only" "meta" "push_ansible_only" "${case4a_env}")"
assert_eq "meta_push_ansible_only" "run_infra_apply" "false" "$(read_plan_json_field "${case4a_out}" '.meta.run_infra_apply')"
assert_eq "meta_push_ansible_only" "run_ansible_bootstrap" "true" "$(read_plan_json_field "${case4a_out}" '.meta.run_ansible_bootstrap')"
assert_eq "meta_push_ansible_only" "run_portainer_apply" "true" "$(read_plan_json_field "${case4a_out}" '.meta.run_portainer_apply')"
assert_eq "meta_push_ansible_only" "run_health_redeploy" "false" "$(read_plan_json_field "${case4a_out}" '.meta.run_health_redeploy')"
assert_eq "meta_push_ansible_only" "reason" "infra-repo-push" "$(read_plan_json_field "${case4a_out}" '.meta.reason')"
assert_eq "meta_push_ansible_only" "stacks_sha" "${STACKS_SHA}" "$(read_plan_json_field "${case4a_out}" '.meta.stacks_sha')"

# Case 4b: dispatch_ansible_only skips infra apply, runs bootstrap + portainer
case4b_env="${TMP_DIR}/case4b.env"
write_env_file "${case4b_env}"
case4b_out="$(run_plan_case "meta_dispatch_ansible_only" "meta" "dispatch_ansible_only" "${case4b_env}")"
assert_eq "meta_dispatch_ansible_only" "run_infra_apply" "false" "$(read_plan_json_field "${case4b_out}" '.meta.run_infra_apply')"
assert_eq "meta_dispatch_ansible_only" "run_ansible_bootstrap" "true" "$(read_plan_json_field "${case4b_out}" '.meta.run_ansible_bootstrap')"
assert_eq "meta_dispatch_ansible_only" "run_portainer_apply" "true" "$(read_plan_json_field "${case4b_out}" '.meta.run_portainer_apply')"
assert_eq "meta_dispatch_ansible_only" "run_health_redeploy" "false" "$(read_plan_json_field "${case4b_out}" '.meta.run_health_redeploy')"
assert_eq "meta_dispatch_ansible_only" "reason" "manual-dispatch" "$(read_plan_json_field "${case4b_out}" '.meta.reason')"
assert_eq "meta_dispatch_ansible_only" "stacks_sha" "${STACKS_SHA}" "$(read_plan_json_field "${case4b_out}" '.meta.stacks_sha')"

# Case 4: iac mode is retired
case4_env="${TMP_DIR}/case4.env"
write_env_file "${case4_env}"
run_plan_case_expect_fail "iac_mode_removed" "iac" "push" "${case4_env}"

# Case 5: validator rejects legacy v4 schema
case5_env="${TMP_DIR}/case5.env"
legacy_payload_json="$(jq -c '.schema_version = "v4"' <<<"${dispatch_payload_json}")"
write_env_file "${case5_env}" \
  "EVENT_NAME=repository_dispatch" \
  "PAYLOAD_JSON=${legacy_payload_json}" \
  "PAYLOAD_STACKS_SHA=${STACKS_SHA}" \
  "PAYLOAD_SOURCE_SHA=${STACKS_SHA}" \
  "PAYLOAD_REASON=full-reconcile" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
run_validator_expect_fail "dispatch_validator_v4_rejected" "${case5_env}"

# Case 6: validator rejects wrong reason
case6_env="${TMP_DIR}/case6.env"
wrong_reason_payload_json="$(jq -c '.reason = "manual-refresh"' <<<"${dispatch_payload_json}")"
write_env_file "${case6_env}" \
  "EVENT_NAME=repository_dispatch" \
  "PAYLOAD_JSON=${wrong_reason_payload_json}" \
  "PAYLOAD_STACKS_SHA=${STACKS_SHA}" \
  "PAYLOAD_SOURCE_SHA=${STACKS_SHA}" \
  "PAYLOAD_REASON=manual-refresh" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
run_validator_expect_fail "dispatch_validator_reason_rejected" "${case6_env}"

# Case 7: validator rejects removed selective fields
case7_env="${TMP_DIR}/case7.env"
removed_field_payload_json="$(jq -c '.changed_stacks = ["gateway"]' <<<"${dispatch_payload_json}")"
write_env_file "${case7_env}" \
  "EVENT_NAME=repository_dispatch" \
  "PAYLOAD_JSON=${removed_field_payload_json}" \
  "PAYLOAD_STACKS_SHA=${STACKS_SHA}" \
  "PAYLOAD_SOURCE_SHA=${STACKS_SHA}" \
  "PAYLOAD_REASON=full-reconcile" \
  "PAYLOAD_SOURCE_REPO=example/stacks" \
  "PAYLOAD_SOURCE_RUN_ID=12345"
run_validator_expect_fail "dispatch_validator_removed_field_rejected" "${case7_env}"

# ── Phase detection tests ──────────────────────────────────────────────────
# Set up a minimal git repo with controlled commits so git diff returns
# predictable output for ansible_tags computation.
_phase_stacks="${TMP_DIR}/phase-stacks"
_phase_repo="${TMP_DIR}/phase-repo"

git init -q -b main "${_phase_stacks}" 2>/dev/null || git init -q "${_phase_stacks}"
git -C "${_phase_stacks}" config user.email "ci@test"
git -C "${_phase_stacks}" config user.name "ci"
git -C "${_phase_stacks}" commit -q --allow-empty -m "init"
_phase_stacks_sha="$(git -C "${_phase_stacks}" rev-parse HEAD)"

git init -q -b main "${_phase_repo}" 2>/dev/null || git init -q "${_phase_repo}"
git -C "${_phase_repo}" config user.email "ci@test"
git -C "${_phase_repo}" config user.name "ci"
# Add a stacks gitlink so git rev-parse HEAD:stacks succeeds.
git -C "${_phase_repo}" update-index --add --cacheinfo "160000,${_phase_stacks_sha},stacks"
git -C "${_phase_repo}" commit -q -m "initial: add stacks gitlink"
_phase_base_sha="$(git -C "${_phase_repo}" rev-parse HEAD)"

# Commit: only ansible/roles/runtime_sync/ changed
mkdir -p "${_phase_repo}/ansible/roles/runtime_sync/tasks"
printf '# task\n' > "${_phase_repo}/ansible/roles/runtime_sync/tasks/main.yml"
git -C "${_phase_repo}" add ansible/roles/runtime_sync/tasks/main.yml
git -C "${_phase_repo}" commit -q -m "change runtime_sync"
_phase_runtime_sha="$(git -C "${_phase_repo}" rev-parse HEAD)"

# Commit: only ansible/roles/glusterfs/ changed
mkdir -p "${_phase_repo}/ansible/roles/glusterfs/tasks"
printf '# task\n' > "${_phase_repo}/ansible/roles/glusterfs/tasks/main.yml"
git -C "${_phase_repo}" add ansible/roles/glusterfs/tasks/main.yml
git -C "${_phase_repo}" commit -q -m "change glusterfs"
_phase_gluster_sha="$(git -C "${_phase_repo}" rev-parse HEAD)"

# Commit: ansible/playbooks/ changed (shared — triggers full-bootstrap fallback)
mkdir -p "${_phase_repo}/ansible/playbooks"
printf '# playbook\n' > "${_phase_repo}/ansible/playbooks/provision.yml"
git -C "${_phase_repo}" add ansible/playbooks/provision.yml
git -C "${_phase_repo}" commit -q -m "change playbook"
_phase_playbook_sha="$(git -C "${_phase_repo}" rev-parse HEAD)"

# Case P1: runtime_sync only → ansible_tags=phase7_runtime_sync
casep1_env="${TMP_DIR}/casep1.env"
write_env_file "${casep1_env}" \
  "PUSH_BEFORE=${_phase_base_sha}" \
  "PUSH_SHA=${_phase_runtime_sha}"
casep1_out="$(run_plan_case_in_dir "phase_runtime_only" "meta" "push_ansible_only" "${casep1_env}" "${_phase_repo}")"
assert_eq "phase_runtime_only" "ansible_tags" "phase7_runtime_sync" "$(read_plan_json_field "${casep1_out}" '.meta.ansible_tags')"
assert_eq "phase_runtime_only" "run_infra_apply" "false" "$(read_plan_json_field "${casep1_out}" '.meta.run_infra_apply')"
assert_eq "phase_runtime_only" "run_ansible_bootstrap" "true" "$(read_plan_json_field "${casep1_out}" '.meta.run_ansible_bootstrap')"

# Case P2: glusterfs + runtime_sync → ansible_tags=phase4_glusterfs,phase7_runtime_sync
casep2_env="${TMP_DIR}/casep2.env"
write_env_file "${casep2_env}" \
  "PUSH_BEFORE=${_phase_base_sha}" \
  "PUSH_SHA=${_phase_gluster_sha}"
casep2_out="$(run_plan_case_in_dir "phase_gluster_and_runtime" "meta" "push_ansible_only" "${casep2_env}" "${_phase_repo}")"
assert_eq "phase_gluster_and_runtime" "ansible_tags" "phase4_glusterfs,phase7_runtime_sync" "$(read_plan_json_field "${casep2_out}" '.meta.ansible_tags')"

# Case P3: playbook change → falls back to full bootstrap (ansible_tags="")
casep3_env="${TMP_DIR}/casep3.env"
write_env_file "${casep3_env}" \
  "PUSH_BEFORE=${_phase_gluster_sha}" \
  "PUSH_SHA=${_phase_playbook_sha}"
casep3_out="$(run_plan_case_in_dir "phase_playbook_fallback" "meta" "push_ansible_only" "${casep3_env}" "${_phase_repo}")"
assert_eq "phase_playbook_fallback" "ansible_tags" "" "$(read_plan_json_field "${casep3_out}" '.meta.ansible_tags')"

# Case P4: regular push always has ansible_tags="" (phase detection only for push_ansible_only)
casep4_env="${TMP_DIR}/casep4.env"
write_env_file "${casep4_env}" \
  "PUSH_BEFORE=${_phase_base_sha}" \
  "PUSH_SHA=${_phase_runtime_sha}"
casep4_out="$(run_plan_case_in_dir "phase_push_no_tags" "meta" "push" "${casep4_env}" "${_phase_repo}")"
assert_eq "phase_push_no_tags" "ansible_tags" "" "$(read_plan_json_field "${casep4_out}" '.meta.ansible_tags')"
assert_eq "phase_push_no_tags" "run_infra_apply" "true" "$(read_plan_json_field "${casep4_out}" '.meta.run_infra_apply')"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
