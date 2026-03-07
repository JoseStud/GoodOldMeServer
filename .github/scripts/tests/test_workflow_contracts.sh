#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ORCHESTRATOR="${ROOT_DIR}/.github/workflows/infra-orchestrator.yml"
PRELIGHT="${ROOT_DIR}/.github/workflows/reusable-orch-preflight.yml"
INFRA="${ROOT_DIR}/.github/workflows/reusable-orch-infra.yml"
ANSIBLE="${ROOT_DIR}/.github/workflows/reusable-orch-ansible.yml"
PORTAINER="${ROOT_DIR}/.github/workflows/reusable-orch-portainer.yml"
PLANNER_VALIDATION="${ROOT_DIR}/.github/workflows/validate-planner-contracts.yml"
TERRAFORM_VALIDATION="${ROOT_DIR}/.github/workflows/validate-terraform.yml"
ANSIBLE_VALIDATION="${ROOT_DIR}/.github/workflows/validate-ansible.yml"
LINT="${ROOT_DIR}/.github/workflows/lint-github-actions.yml"
REUSABLE="${ROOT_DIR}/.github/workflows/reusable-resolve-plan.yml"
PREPARE_ANSIBLE_STAGE="${ROOT_DIR}/.github/actions/prepare-ansible-stage/action.yml"
RETIRED_VALIDATION="${ROOT_DIR}/.github/workflows/infra-validation.yml"
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

assert_file_exists() {
  local case_name="$1"
  local file="$2"

  if [[ -f "${file}" ]]; then
    pass "${case_name}: ${file} exists"
  else
    fail "${case_name}: missing ${file}"
  fi
}

assert_file_absent() {
  local case_name="$1"
  local file="$2"

  if [[ ! -e "${file}" ]]; then
    pass "${case_name}: ${file} absent"
  else
    fail "${case_name}: expected ${file} to be absent"
  fi
}

assert_array_contains() {
  local case_name="$1"
  local key="$2"
  local expected="$3"
  local json_array="$4"

  if jq -e --arg expected "${expected}" 'index($expected) != null' >/dev/null <<<"${json_array}"; then
    pass "${case_name}: ${key} contains ${expected}"
  else
    fail "${case_name}: ${key} missing ${expected}"
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

assert_job_uses() {
  local case_name="$1"
  local file="$2"
  local job_id="$3"
  local expected="$4"
  local actual

  actual="$(yq -r ".jobs.\"${job_id}\".uses // \"\"" "${file}")"
  assert_eq "${case_name}" "${job_id}.uses" "${expected}" "${actual}"
}

assert_job_needs() {
  local case_name="$1"
  local file="$2"
  local job_id="$3"
  local expected_json="$4"
  local actual

  actual="$(yq ".jobs.\"${job_id}\".needs" "${file}" | jq -c '.')"
  assert_eq "${case_name}" "${job_id}.needs" "${expected_json}" "${actual}"
}

assert_line_order() {
  local case_name="$1"
  shift
  local previous_line=0
  local item

  for item in "$@"; do
    local current_line
    current_line="$(rg -n "^  ${item}:" "${ORCHESTRATOR}" | cut -d: -f1 | head -n1)"
    if [[ -z "${current_line}" ]]; then
      fail "${case_name}: missing ${item}"
      return
    fi
    if (( current_line > previous_line )); then
      previous_line="${current_line}"
    else
      fail "${case_name}: ${item} appears out of order"
      return
    fi
  done

  pass "${case_name}: ${*}"
}

assert_run_present() {
  local case_name="$1"
  local file="$2"
  local command="$3"

  if rg -F -- "${command}" "${file}" >/dev/null; then
    pass "${case_name}: ${command}"
  else
    fail "${case_name}: missing ${command}"
  fi
}

assert_trigger_path_contains() {
  local case_name="$1"
  local file="$2"
  local event="$3"
  local expected="$4"
  local paths

  paths="$(yq ".on.${event}.paths" "${file}" | jq -c '.')"
  assert_array_contains "${case_name}" "${event}.paths" "${expected}" "${paths}"
}

for workflow in \
  "${ORCHESTRATOR}" \
  "${PRELIGHT}" \
  "${INFRA}" \
  "${ANSIBLE}" \
  "${PORTAINER}" \
  "${PLANNER_VALIDATION}" \
  "${TERRAFORM_VALIDATION}" \
  "${ANSIBLE_VALIDATION}" \
  "${LINT}" \
  "${REUSABLE}" \
  "${PREPARE_ANSIBLE_STAGE}"; do
  assert_file_exists "active_workflows" "${workflow}"
done

assert_file_absent "retired_workflows" "${RETIRED_VALIDATION}"
assert_file_absent "retired_workflows" "${PATH_FILTERS}"

orchestrator_jobs="$(yq '.jobs | keys' "${ORCHESTRATOR}" | jq -c 'sort')"
assert_eq "orchestrator_shape" "jobs" '["ansible","infra","portainer","preflight","resolve-context"]' "${orchestrator_jobs}"
assert_job_uses "orchestrator_shape" "${ORCHESTRATOR}" "resolve-context" "./.github/workflows/reusable-resolve-plan.yml"
assert_job_uses "orchestrator_shape" "${ORCHESTRATOR}" "preflight" "./.github/workflows/reusable-orch-preflight.yml"
assert_job_uses "orchestrator_shape" "${ORCHESTRATOR}" "infra" "./.github/workflows/reusable-orch-infra.yml"
assert_job_uses "orchestrator_shape" "${ORCHESTRATOR}" "ansible" "./.github/workflows/reusable-orch-ansible.yml"
assert_job_uses "orchestrator_shape" "${ORCHESTRATOR}" "portainer" "./.github/workflows/reusable-orch-portainer.yml"
assert_job_needs "orchestrator_shape" "${ORCHESTRATOR}" "preflight" '["resolve-context"]'
assert_job_needs "orchestrator_shape" "${ORCHESTRATOR}" "infra" '["resolve-context","preflight"]'
assert_job_needs "orchestrator_shape" "${ORCHESTRATOR}" "ansible" '["resolve-context","preflight","infra"]'
assert_job_needs "orchestrator_shape" "${ORCHESTRATOR}" "portainer" '["resolve-context","preflight","ansible"]'
assert_line_order "orchestrator_ordering" resolve-context preflight infra ansible portainer

dispatch_types="$(yq '.on.repository_dispatch.types' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_dispatch" "types" '["stacks-redeploy-intent-v5"]' "${dispatch_types}"
assert_eq "orchestrator_dispatch" "workflow_dispatch" "null" "$(yq '.on.workflow_dispatch // null' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_dispatch" "workflow_call" "null" "$(yq '.on.workflow_call // null' "${ORCHESTRATOR}" | jq -c '.')"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" "stacks"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" ".gitmodules"

reusable_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${REUSABLE}" | jq -c '.')"
assert_eq "resolve_plan_contract" "inputs" '["dispatch_payload_json","dispatch_reason","dispatch_schema_version","dispatch_source_repo","dispatch_source_run_id","dispatch_source_sha","dispatch_stacks_sha","push_before","push_sha","source_event_name"]' "${reusable_inputs}"
if rg -n 'dorny/paths-filter|META_FILTER_APPLIED|META_INFRA_CHANGED|META_ANSIBLE_CHANGED|META_PORTAINER_CHANGED|path-filters\.yml|Detect changed paths' "${REUSABLE}" >/dev/null; then
  fail "resolve_plan_contract: found retired path-detection references"
else
  pass "resolve_plan_contract: no retired path-detection references"
fi

preflight_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${PRELIGHT}" | jq -c '.')"
assert_eq "preflight_contract" "inputs" '["plan_json"]' "${preflight_inputs}"
preflight_outputs="$(yq '.on.workflow_call.outputs | keys | sort' "${PRELIGHT}" | jq -c '.')"
assert_eq "preflight_contract" "outputs" '["network_access_policy_json","portainer_automation_allowed_cidrs","runner_label"]' "${preflight_outputs}"

infra_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${INFRA}" | jq -c '.')"
assert_eq "infra_contract" "inputs" '["network_access_policy_json","plan_json","runner_label"]' "${infra_inputs}"

ansible_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${ANSIBLE}" | jq -c '.')"
assert_eq "ansible_contract" "inputs" '["plan_json","runner_label"]' "${ansible_inputs}"

portainer_inputs="$(yq '.on.workflow_call.inputs | keys | sort' "${PORTAINER}" | jq -c '.')"
assert_eq "portainer_contract" "inputs" '["network_access_policy_json","plan_json","runner_label"]' "${portainer_inputs}"

inventory_upload_name="$(yq -r '.jobs."inventory-handover".steps[] | select(.uses == "actions/upload-artifact@v4") | .with.name' "${INFRA}")"
inventory_upload_path="$(yq -r '.jobs."inventory-handover".steps[] | select(.uses == "actions/upload-artifact@v4") | .with.path' "${INFRA}")"
assert_eq "inventory_contract" "upload_name" "inventory-ci" "${inventory_upload_name}"
assert_eq "inventory_contract" "upload_path" "inventory-ci.yml" "${inventory_upload_path}"

inventory_render_output="$(yq -r '.jobs."inventory-handover".steps[] | select(.run != null) | .env.OUTPUT_FILE // empty' "${INFRA}" | head -n1)"
assert_eq "inventory_contract" "render_output" "inventory-ci.yml" "${inventory_render_output}"

prepare_ansible_inventory_name="$(yq -r '.inputs.inventory_artifact_name.default' "${PREPARE_ANSIBLE_STAGE}")"
assert_eq "inventory_contract" "prepare_ansible_default_artifact" "inventory-ci" "${prepare_ansible_inventory_name}"

prepare_ansible_usage_count="$(
  rg -c 'uses: \./\.github/actions/prepare-ansible-stage' "${ANSIBLE}" "${PORTAINER}" \
    | awk -F: '{sum += $2} END {print sum + 0}'
)"
prepare_ansible_download_disabled_count="$(
  rg -c 'download_inventory: "false"' "${PORTAINER}" \
    | awk -F: '{sum += $2} END {print sum + 0}'
)"
explicit_inventory_download_count="$(
  rg -c 'uses: actions/download-artifact@v4' "${INFRA}" \
    | awk -F: '{sum += $2} END {print sum + 0}'
)"
inventory_download_count="$((prepare_ansible_usage_count - prepare_ansible_download_disabled_count + explicit_inventory_download_count))"
assert_eq "inventory_contract" "download_count" "4" "${inventory_download_count}"

network_policy_needs="$(yq '.jobs."network-policy-sync".needs' "${PRELIGHT}" | jq -c '.')"
assert_array_contains "preflight_gating" "network_policy_sync.needs" "stacks-sha-trust" "${network_policy_needs}"
network_policy_if="$(yq -r '.jobs."network-policy-sync".if' "${PRELIGHT}")"
assert_contains_text "preflight_gating" "network_policy_sync.if" "needs.stacks-sha-trust.result == 'success'" "${network_policy_if}"

portainer_needs="$(yq '.jobs."portainer-apply".needs' "${PORTAINER}" | jq -c '.')"
assert_array_contains "portainer_gating" "portainer_apply.needs" "config-sync" "${portainer_needs}"
health_needs="$(yq '.jobs."health-gated-redeploy".needs' "${PORTAINER}" | jq -c '.')"
assert_array_contains "portainer_gating" "health_gated_redeploy.needs" "config-sync" "${health_needs}"
portainer_apply_if="$(yq -r '.jobs."portainer-apply".if' "${PORTAINER}")"
assert_contains_text "portainer_gating" "portainer_apply.if" "stage_config_sync != true" "${portainer_apply_if}"

stacks_sha_trust_if="$(yq -r '.jobs."stacks-sha-trust".if' "${PRELIGHT}")"
assert_contains_text "stacks_sha_trust" "if" "stage_host_sync == true" "${stacks_sha_trust_if}"
assert_contains_text "stacks_sha_trust" "if" "stage_portainer_apply == true" "${stacks_sha_trust_if}"
assert_contains_text "stacks_sha_trust" "if" "stage_config_sync == true" "${stacks_sha_trust_if}"
assert_contains_text "stacks_sha_trust" "if" "stage_health_gated_redeploy == true" "${stacks_sha_trust_if}"

planner_jobs="$(yq '.jobs | keys' "${PLANNER_VALIDATION}" | jq -c 'sort')"
assert_eq "planner_validation" "jobs" '["bootstrap-tools-smoke","planner-contract-tests","stacks-sha-trust","workflow-contracts"]' "${planner_jobs}"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_resolve_ci_plan.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_preflight_network_access.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_portainer_apply.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_trigger_webhooks_with_gates.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_workflow_contracts.sh"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" ".gitmodules"

terraform_jobs="$(yq '.jobs | keys' "${TERRAFORM_VALIDATION}" | jq -c 'sort')"
assert_eq "terraform_validation" "jobs" '["terraform-fmt","terraform-validate","tfc-speculative-plan"]' "${terraform_jobs}"
tfc_directory="$(yq -r '.jobs."tfc-speculative-plan".steps[] | select(.uses == "hashicorp/tfc-workflows-github/actions/upload-configuration@v1.0.0") | .with.directory' "${TERRAFORM_VALIDATION}")"
assert_eq "terraform_validation" "tfc_directory" "terraform/infra" "${tfc_directory}"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "pull_request" ".gitmodules"

ansible_jobs="$(yq '.jobs | keys' "${ANSIBLE_VALIDATION}" | jq -c 'sort')"
assert_eq "ansible_validation" "jobs" '["ansible-validate"]' "${ansible_jobs}"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "pull_request" ".gitmodules"

planner_dispatch_present="$(yq '.on | has("workflow_dispatch")' "${PLANNER_VALIDATION}" | jq -c '.')"
terraform_dispatch_present="$(yq '.on | has("workflow_dispatch")' "${TERRAFORM_VALIDATION}" | jq -c '.')"
ansible_dispatch_present="$(yq '.on | has("workflow_dispatch")' "${ANSIBLE_VALIDATION}" | jq -c '.')"
lint_dispatch_present="$(yq '.on | has("workflow_dispatch")' "${LINT}" | jq -c '.')"
assert_eq "validation_dispatch" "planner" "true" "${planner_dispatch_present}"
assert_eq "validation_dispatch" "terraform" "true" "${terraform_dispatch_present}"
assert_eq "validation_dispatch" "ansible" "true" "${ansible_dispatch_present}"
assert_eq "validation_dispatch" "lint" "true" "${lint_dispatch_present}"

lint_push_docs="$(yq '.on.push.paths' "${LINT}" | jq -e 'index("docs/**") != null' >/dev/null && echo true || echo false)"
lint_push_readme="$(yq '.on.push.paths' "${LINT}" | jq -e 'index("README.md") != null' >/dev/null && echo true || echo false)"
assert_eq "lint_paths" "push_docs" "true" "${lint_push_docs}"
assert_eq "lint_paths" "push_readme" "true" "${lint_push_readme}"
assert_trigger_path_contains "lint_paths" "${LINT}" "push" "stacks"
assert_trigger_path_contains "lint_paths" "${LINT}" "push" ".gitmodules"
assert_trigger_path_contains "lint_paths" "${LINT}" "pull_request" "stacks"
assert_trigger_path_contains "lint_paths" "${LINT}" "pull_request" ".gitmodules"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
