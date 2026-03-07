#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ORCHESTRATOR="${ROOT_DIR}/.github/workflows/infra-orchestrator.yml"
VALIDATION="${ROOT_DIR}/.github/workflows/infra-validation.yml"
LINT="${ROOT_DIR}/.github/workflows/lint-github-actions.yml"
REUSABLE="${ROOT_DIR}/.github/workflows/reusable-resolve-plan.yml"
PATH_FILTERS="${ROOT_DIR}/.github/ci/path-filters.yml"

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

assert_contains_text() {
  local case_name="$1"
  local key="$2"
  local needle="$3"
  local haystack="$4"

  if grep -Fq -- "${needle}" <<<"${haystack}"; then
    pass "${case_name}: ${key} contains '${needle}'"
  else
    fail "${case_name}: ${key} missing '${needle}'"
  fi
}

assert_not_contains_text() {
  local case_name="$1"
  local key="$2"
  local needle="$3"
  local haystack="$4"

  if grep -Fq -- "${needle}" <<<"${haystack}"; then
    fail "${case_name}: ${key} unexpectedly contains '${needle}'"
  else
    pass "${case_name}: ${key} excludes '${needle}'"
  fi
}

dispatch_types="$(yq '.on.repository_dispatch.types' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_dispatch" "types" '["stacks-redeploy-intent-v5"]' "${dispatch_types}"

assert_absent "orchestrator_triggers_removed" '.on.workflow_dispatch' "${ORCHESTRATOR}"
assert_absent "orchestrator_triggers_removed" '.on.workflow_call' "${ORCHESTRATOR}"

health_redeploy_full_reconcile="$(yq -r '.jobs."health-gated-redeploy".steps[] | select(.name == "Trigger health-gated webhooks") | .env.FULL_STACKS_RECONCILE' "${ORCHESTRATOR}")"
assert_eq "orchestrator_redeploy" "full_reconcile_env" "true" "${health_redeploy_full_reconcile}"
assert_no_match "orchestrator_redeploy" 'STACKS_CSV' "${ORCHESTRATOR}"

portainer_needs_config="$(yq '.jobs."portainer-apply".needs' "${ORCHESTRATOR}" | jq -e 'index("config-sync") != null' >/dev/null && echo true || echo false)"
assert_eq "orchestrator_ordering" "portainer_needs_config_sync" "true" "${portainer_needs_config}"

portainer_needs_stacks_trust="$(yq '.jobs."portainer-apply".needs' "${ORCHESTRATOR}" | jq -e 'index("stacks-sha-trust") != null' >/dev/null && echo true || echo false)"
assert_eq "orchestrator_ordering" "portainer_needs_stacks_sha_trust" "true" "${portainer_needs_stacks_trust}"

config_needs_portainer="$(yq '.jobs."config-sync".needs' "${ORCHESTRATOR}" | jq -e 'index("portainer-apply") != null' >/dev/null && echo true || echo false)"
assert_eq "orchestrator_ordering" "config_needs_portainer_apply" "false" "${config_needs_portainer}"

stacks_sha_trust_if="$(yq -r '.jobs."stacks-sha-trust".if' "${ORCHESTRATOR}")"
if grep -Fq "stage_portainer_apply == 'true'" <<<"${stacks_sha_trust_if}"; then
  pass "orchestrator_stacks_sha_trust: includes stage_portainer_apply"
else
  fail "orchestrator_stacks_sha_trust: missing stage_portainer_apply in if condition"
fi

reusable_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${REUSABLE}" | jq -c '.')"
assert_eq "reusable_contract" "inputs" '["dispatch_payload_json","dispatch_reason","dispatch_schema_version","dispatch_source_repo","dispatch_source_run_id","dispatch_source_sha","dispatch_stacks_sha","push_before","push_sha","source_event_name"]' "${reusable_inputs}"
assert_absent "reusable_contract" '.on.workflow_call.inputs.plan_mode' "${REUSABLE}"
assert_absent "reusable_contract" '.on.workflow_call.inputs.changed_stacks_json' "${REUSABLE}"
assert_no_match "reusable_contract" 'dorny/paths-filter|META_FILTER_APPLIED|META_INFRA_CHANGED|META_ANSIBLE_CHANGED|META_PORTAINER_CHANGED|path-filters\.yml|Detect changed paths' "${REUSABLE}"

if [[ -e "${PATH_FILTERS}" ]]; then
  fail "reusable_contract: expected ${PATH_FILTERS} to be absent"
else
  pass "reusable_contract: ${PATH_FILTERS} absent"
fi

validation_dispatch_present="$(yq '.on | has("workflow_dispatch")' "${VALIDATION}" | jq -c '.')"
assert_eq "validation_dispatch" "present" "true" "${validation_dispatch_present}"

lint_dispatch_present="$(yq '.on | has("workflow_dispatch")' "${LINT}" | jq -c '.')"
assert_eq "lint_dispatch" "present" "true" "${lint_dispatch_present}"

lint_push_docs="$(yq '.on.push.paths' "${LINT}" | jq -e 'index("docs/**") != null' >/dev/null && echo true || echo false)"
assert_eq "lint_paths" "push_docs" "true" "${lint_push_docs}"

lint_push_readme="$(yq '.on.push.paths' "${LINT}" | jq -e 'index("README.md") != null' >/dev/null && echo true || echo false)"
assert_eq "lint_paths" "push_readme" "true" "${lint_push_readme}"

lint_pr_docs="$(yq '.on.pull_request.paths' "${LINT}" | jq -e 'index("docs/**") != null' >/dev/null && echo true || echo false)"
assert_eq "lint_paths" "pull_request_docs" "true" "${lint_pr_docs}"

lint_pr_readme="$(yq '.on.pull_request.paths' "${LINT}" | jq -e 'index("README.md") != null' >/dev/null && echo true || echo false)"
assert_eq "lint_paths" "pull_request_readme" "true" "${lint_pr_readme}"

inventory_handover_if="$(yq -r '.jobs."inventory-handover".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "inventory_handover_if" "needs.secret-validation.result == 'success'" "${inventory_handover_if}"

network_preflight_if="$(yq -r '.jobs."network-preflight-ssh".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "network_preflight_if" "needs.cloud-runner-guard.result == 'success'" "${network_preflight_if}"
assert_contains_text "orchestrator_guards" "network_preflight_if" "needs.secret-validation.result == 'success'" "${network_preflight_if}"
assert_contains_text "orchestrator_guards" "network_preflight_if" "needs.network-policy-sync.result == 'success'" "${network_preflight_if}"
assert_contains_text "orchestrator_guards" "network_preflight_if" "needs.inventory-handover.result == 'success'" "${network_preflight_if}"
assert_not_contains_text "orchestrator_guards" "network_preflight_if" "always()" "${network_preflight_if}"

host_sync_if="$(yq -r '.jobs."host-sync".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "host_sync_if" "needs.stacks-sha-trust.result == 'success'" "${host_sync_if}"
assert_contains_text "orchestrator_guards" "host_sync_if" "needs.secret-validation.result == 'success'" "${host_sync_if}"
assert_contains_text "orchestrator_guards" "host_sync_if" "needs.cloud-runner-guard.result == 'success'" "${host_sync_if}"
assert_contains_text "orchestrator_guards" "host_sync_if" "needs.network-preflight-ssh.result == 'success'" "${host_sync_if}"
assert_contains_text "orchestrator_guards" "host_sync_if" "needs.inventory-handover.result == 'success'" "${host_sync_if}"
assert_not_contains_text "orchestrator_guards" "host_sync_if" "always()" "${host_sync_if}"

post_bootstrap_if="$(yq -r '.jobs."post-bootstrap-secret-check".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "post_bootstrap_if" "needs.secret-validation.result == 'success'" "${post_bootstrap_if}"
assert_contains_text "orchestrator_guards" "post_bootstrap_if" "needs.project-plan.outputs.stage_ansible_bootstrap != 'true'" "${post_bootstrap_if}"

portainer_preflight_if="$(yq -r '.jobs."portainer-api-preflight".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "portainer_preflight_if" "needs.cloud-runner-guard.result == 'success'" "${portainer_preflight_if}"
assert_contains_text "orchestrator_guards" "portainer_preflight_if" "needs.secret-validation.result == 'success'" "${portainer_preflight_if}"
assert_contains_text "orchestrator_guards" "portainer_preflight_if" "needs.network-policy-sync.result == 'success'" "${portainer_preflight_if}"
assert_contains_text "orchestrator_guards" "portainer_preflight_if" "needs.post-bootstrap-secret-check.result == 'success'" "${portainer_preflight_if}"
assert_contains_text "orchestrator_guards" "portainer_preflight_if" "needs.project-plan.outputs.stage_host_sync != 'true'" "${portainer_preflight_if}"
assert_not_contains_text "orchestrator_guards" "portainer_preflight_if" "needs.post-bootstrap-secret-check.result == 'skipped'" "${portainer_preflight_if}"

portainer_apply_if="$(yq -r '.jobs."portainer-apply".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "portainer_apply_if" "needs.secret-validation.result == 'success'" "${portainer_apply_if}"
assert_contains_text "orchestrator_guards" "portainer_apply_if" "needs.cloud-runner-guard.result == 'success'" "${portainer_apply_if}"
assert_contains_text "orchestrator_guards" "portainer_apply_if" "needs.network-policy-sync.result == 'success'" "${portainer_apply_if}"
assert_contains_text "orchestrator_guards" "portainer_apply_if" "needs.post-bootstrap-secret-check.result == 'success'" "${portainer_apply_if}"
assert_contains_text "orchestrator_guards" "portainer_apply_if" "needs.portainer-api-preflight.result == 'success'" "${portainer_apply_if}"
assert_contains_text "orchestrator_guards" "portainer_apply_if" "needs.project-plan.outputs.stacks_sha == ''" "${portainer_apply_if}"
assert_contains_text "orchestrator_guards" "portainer_apply_if" "needs.project-plan.outputs.stage_config_sync != 'true'" "${portainer_apply_if}"
assert_not_contains_text "orchestrator_guards" "portainer_apply_if" "needs.portainer-api-preflight.result == 'skipped'" "${portainer_apply_if}"

config_sync_if="$(yq -r '.jobs."config-sync".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "config_sync_if" "needs.stacks-sha-trust.result == 'success'" "${config_sync_if}"
assert_contains_text "orchestrator_guards" "config_sync_if" "needs.secret-validation.result == 'success'" "${config_sync_if}"
assert_contains_text "orchestrator_guards" "config_sync_if" "needs.cloud-runner-guard.result == 'success'" "${config_sync_if}"
assert_contains_text "orchestrator_guards" "config_sync_if" "needs.network-preflight-ssh.result == 'success'" "${config_sync_if}"
assert_contains_text "orchestrator_guards" "config_sync_if" "needs.inventory-handover.result == 'success'" "${config_sync_if}"
assert_contains_text "orchestrator_guards" "config_sync_if" "needs.host-sync.result == 'success'" "${config_sync_if}"
assert_not_contains_text "orchestrator_guards" "config_sync_if" "always()" "${config_sync_if}"

health_redeploy_if="$(yq -r '.jobs."health-gated-redeploy".if' "${ORCHESTRATOR}")"
assert_contains_text "orchestrator_guards" "health_redeploy_if" "needs.stacks-sha-trust.result == 'success'" "${health_redeploy_if}"
assert_contains_text "orchestrator_guards" "health_redeploy_if" "needs.secret-validation.result == 'success'" "${health_redeploy_if}"
assert_contains_text "orchestrator_guards" "health_redeploy_if" "needs.cloud-runner-guard.result == 'success'" "${health_redeploy_if}"
assert_contains_text "orchestrator_guards" "health_redeploy_if" "needs.host-sync.result == 'success'" "${health_redeploy_if}"
assert_contains_text "orchestrator_guards" "health_redeploy_if" "needs.portainer-api-preflight.result == 'success'" "${health_redeploy_if}"
assert_contains_text "orchestrator_guards" "health_redeploy_if" "needs.portainer-apply.result == 'success'" "${health_redeploy_if}"
assert_contains_text "orchestrator_guards" "health_redeploy_if" "needs.config-sync.result == 'success'" "${health_redeploy_if}"
assert_not_contains_text "orchestrator_guards" "health_redeploy_if" "always()" "${health_redeploy_if}"
assert_not_contains_text "orchestrator_guards" "health_redeploy_if" "needs.portainer-api-preflight.result == 'skipped'" "${health_redeploy_if}"
assert_not_contains_text "orchestrator_guards" "health_redeploy_if" "needs.portainer-apply.result == 'skipped'" "${health_redeploy_if}"
assert_not_contains_text "orchestrator_guards" "health_redeploy_if" "needs.config-sync.result == 'skipped'" "${health_redeploy_if}"

assert_absent "validation_jobs_removed" '.jobs."detect-impact"' "${VALIDATION}"
assert_absent "validation_jobs_removed" '.jobs."project-impact"' "${VALIDATION}"
assert_no_match "validation_removed_references" 'changed_tf_roots|tfc_workspace_matrix|plan_mode: iac|project_plan_outputs\.sh iac' "${VALIDATION}"

terraform_roots="$(yq '.jobs."terraform-validate".strategy.matrix.root' "${VALIDATION}" | jq -c '.')"
assert_eq "validation_fixed_suite" "terraform_roots" '["terraform/infra","terraform/oci","terraform/gcp","terraform/portainer-root","terraform/portainer"]' "${terraform_roots}"

network_preflight_test_run="$(yq -r '.jobs."planner-contract-tests".steps[] | select(.name == "Run network preflight tests") | .run // empty' "${VALIDATION}")"
assert_eq "validation_fixed_suite" "network_preflight_test_run" "bash .github/scripts/tests/test_preflight_network_access.sh" "${network_preflight_test_run}"

portainer_apply_test_run="$(yq -r '.jobs."planner-contract-tests".steps[] | select(.name == "Run Portainer apply tests") | .run // empty' "${VALIDATION}")"
assert_eq "validation_fixed_suite" "portainer_apply_test_run" "bash .github/scripts/tests/test_portainer_apply.sh" "${portainer_apply_test_run}"

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
