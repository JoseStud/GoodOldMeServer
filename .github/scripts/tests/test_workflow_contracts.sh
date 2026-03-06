#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ORCHESTRATOR="${ROOT_DIR}/.github/workflows/infra-orchestrator.yml"
VALIDATION="${ROOT_DIR}/.github/workflows/infra-validation.yml"
REUSABLE="${ROOT_DIR}/.github/workflows/reusable-detect-impact-resolve-plan.yml"

if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: yq and jq are required to run workflow contract tests."
  exit 0
fi

PASS_COUNT=0
FAIL_COUNT=0

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

assert_absent() {
  local case_name="$1"
  local path_expr="$2"
  local file="$3"
  local value
  value="$(yq "${path_expr} // null" "${file}" | jq -c '.')"
  if [[ "${value}" == "null" ]]; then
    pass "${case_name}: ${path_expr} absent"
  else
    fail "${case_name}: expected ${path_expr} to be absent, found ${value}"
  fi
}

assert_no_match() {
  local case_name="$1"
  local pattern="$2"
  local file="$3"
  if rg -n "${pattern}" "${file}" >/dev/null; then
    fail "${case_name}: unexpected match for ${pattern} in ${file}"
  else
    pass "${case_name}: no match for ${pattern}"
  fi
}

dispatch_types="$(yq '.on.repository_dispatch.types' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_dispatch" "types" '["stacks-redeploy-intent-v5"]' "${dispatch_types}"

workflow_dispatch_inputs="$(yq '.on.workflow_dispatch.inputs | keys | sort' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_inputs" "workflow_dispatch" '["break_glass_policy_json","dry_run","reason","run_ansible_bootstrap","run_infra_apply","run_portainer_apply","stacks_sha"]' "${workflow_dispatch_inputs}"

workflow_call_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_inputs" "workflow_call" '["break_glass_policy_json","dry_run","reason","run_ansible_bootstrap","run_infra_apply","run_portainer_apply","stacks_sha"]' "${workflow_call_inputs}"

assert_absent "orchestrator_inputs_removed" '.on.workflow_dispatch.inputs.changed_stacks_json' "${ORCHESTRATOR}"
assert_absent "orchestrator_inputs_removed" '.on.workflow_dispatch.inputs.host_sync_stacks_json' "${ORCHESTRATOR}"
assert_absent "orchestrator_inputs_removed" '.on.workflow_dispatch.inputs.config_stacks_json' "${ORCHESTRATOR}"
assert_absent "orchestrator_inputs_removed" '.on.workflow_dispatch.inputs.structural_change' "${ORCHESTRATOR}"
assert_absent "orchestrator_inputs_removed" '.on.workflow_dispatch.inputs.changed_paths_json' "${ORCHESTRATOR}"

health_redeploy_full_reconcile="$(yq -r '.jobs."health-gated-redeploy".steps[] | select(.name == "Trigger health-gated webhooks") | .env.FULL_STACKS_RECONCILE' "${ORCHESTRATOR}")"
assert_eq "orchestrator_redeploy" "full_reconcile_env" "true" "${health_redeploy_full_reconcile}"
assert_no_match "orchestrator_redeploy" 'STACKS_CSV' "${ORCHESTRATOR}"

portainer_needs_config="$(yq '.jobs."portainer-apply".needs' "${ORCHESTRATOR}" | jq -e 'index("config-sync") != null' >/dev/null && echo true || echo false)"
assert_eq "orchestrator_ordering" "portainer_needs_config_sync" "true" "${portainer_needs_config}"

config_needs_portainer="$(yq '.jobs."config-sync".needs' "${ORCHESTRATOR}" | jq -e 'index("portainer-apply") != null' >/dev/null && echo true || echo false)"
assert_eq "orchestrator_ordering" "config_needs_portainer_apply" "false" "${config_needs_portainer}"

reusable_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${REUSABLE}" | jq -c '.')"
assert_eq "reusable_contract" "inputs" '["dispatch_payload_json","dispatch_reason","dispatch_schema_version","dispatch_source_repo","dispatch_source_run_id","dispatch_source_sha","dispatch_stacks_sha","push_before","push_sha","reason","run_ansible_bootstrap","run_infra_apply","run_portainer_apply","source_event_name","stacks_sha"]' "${reusable_inputs}"
assert_absent "reusable_contract" '.on.workflow_call.inputs.plan_mode' "${REUSABLE}"
assert_absent "reusable_contract" '.on.workflow_call.inputs.changed_stacks_json' "${REUSABLE}"

assert_absent "validation_jobs_removed" '.jobs."detect-impact"' "${VALIDATION}"
assert_absent "validation_jobs_removed" '.jobs."project-impact"' "${VALIDATION}"
assert_no_match "validation_removed_references" 'changed_tf_roots|tfc_workspace_matrix|plan_mode: iac|project_plan_outputs\.sh iac' "${VALIDATION}"

terraform_roots="$(yq '.jobs."terraform-validate".strategy.matrix.root' "${VALIDATION}" | jq -c '.')"
assert_eq "validation_fixed_suite" "terraform_roots" '["terraform/infra","terraform/oci","terraform/gcp","terraform/portainer-root","terraform/portainer"]' "${terraform_roots}"

tfc_directory="$(yq -r '.jobs."tfc-speculative-plan".steps[] | select(.name == "Upload configuration") | .with.directory' "${VALIDATION}")"
assert_eq "validation_fixed_suite" "tfc_directory" "terraform/infra" "${tfc_directory}"

ansible_if="$(yq '.jobs."ansible-validate".if // null' "${VALIDATION}" | jq -c '.')"
assert_eq "validation_fixed_suite" "ansible_if" "null" "${ansible_if}"

stacks_if="$(yq '.jobs."stacks-sha-trust".if // null' "${VALIDATION}" | jq -c '.')"
assert_eq "validation_fixed_suite" "stacks_sha_trust_if" "null" "${stacks_if}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
