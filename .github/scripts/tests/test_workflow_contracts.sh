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
BOOTSTRAP_TOOLS="${ROOT_DIR}/.github/actions/bootstrap-tools/action.yml"

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

  actual="$(yq -o=json ".jobs.\"${job_id}\".needs" "${file}" | jq -c '.')"
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

  paths="$(yq -o=json ".on.${event}.paths" "${file}" | jq -c '.')"
  assert_array_contains "${case_name}" "${event}.paths" "${expected}" "${paths}"
}

assert_no_regex_match() {
  local case_name="$1"
  local pattern="$2"
  shift 2

  if rg -n -- "${pattern}" "$@" >/dev/null; then
    fail "${case_name}: found pattern '${pattern}'"
  else
    pass "${case_name}: pattern '${pattern}' absent"
  fi
}

job_ids_with_step_uses() {
  local file="$1"
  local step_uses="$2"

  yq -o=json '.jobs' "${file}" | jq -c --arg step_uses "${step_uses}" '
    to_entries
    | map(select((.value.steps // []) | map(.uses // "") | index($step_uses)))
    | map(.key)
    | sort
  '
}

assert_checkout_before_local_actions() {
  local case_name="$1"
  shift

  local file
  local failed="false"

  for file in "$@"; do
    local violations
    violations="$(
      yq -o=json '.jobs' "${file}" | jq -r '
        to_entries[]
        | select(.value.steps != null)
        | .key as $job_id
        | reduce (.value.steps[]?) as $step (
            {checkout_seen: false, violation: false};
            if .violation then .
            elif (($step.uses // "") == "actions/checkout@v4") then .checkout_seen = true
            elif (($step.uses // "") | startswith("./.github/actions/")) and (.checkout_seen | not) then .violation = true
            else .
            end
          )
        | select(.violation)
        | $job_id
      '
    )"

    if [[ -n "${violations}" ]]; then
      while IFS= read -r job_id; do
        [[ -z "${job_id}" ]] && continue
        fail "${case_name}: ${file} job ${job_id} uses a local action before checkout"
      done <<< "${violations}"
      failed="true"
    fi
  done

  if [[ "${failed}" == "false" ]]; then
    pass "${case_name}: local action steps all follow checkout"
  fi
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
  "${BOOTSTRAP_TOOLS}"; do
  assert_file_exists "active_workflows" "${workflow}"
done

assert_checkout_before_local_actions \
  "local_action_bootstrap_order" \
  "${PRELIGHT}" \
  "${INFRA}" \
  "${ANSIBLE}" \
  "${PORTAINER}" \
  "${PLANNER_VALIDATION}" \
  "${TERRAFORM_VALIDATION}" \
  "${LINT}" \
  "${REUSABLE}"

orchestrator_jobs="$(yq -o=json '.jobs | keys' "${ORCHESTRATOR}" | jq -c 'sort')"
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

dispatch_types="$(yq -o=json '.on.repository_dispatch.types' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_dispatch" "types" '["stacks-redeploy-intent-v5"]' "${dispatch_types}"
assert_eq "orchestrator_dispatch" "workflow_dispatch" "null" "$(yq -o=json '.on.workflow_dispatch // null' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_dispatch" "workflow_call" "null" "$(yq -o=json '.on.workflow_call // null' "${ORCHESTRATOR}" | jq -c '.')"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" "stacks"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" ".gitmodules"

reusable_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${REUSABLE}" | jq -c '.')"
assert_eq "resolve_plan_contract" "inputs" '["dispatch_payload_json","dispatch_reason","dispatch_schema_version","dispatch_source_repo","dispatch_source_run_id","dispatch_source_sha","dispatch_stacks_sha","push_before","push_sha","source_event_name"]' "${reusable_inputs}"
if rg -n 'dorny/paths-filter|META_FILTER_APPLIED|META_INFRA_CHANGED|META_ANSIBLE_CHANGED|META_PORTAINER_CHANGED|path-filters\.yml|Detect changed paths' "${REUSABLE}" >/dev/null; then
  fail "resolve_plan_contract: found retired path-detection references"
else
  pass "resolve_plan_contract: no retired path-detection references"
fi

preflight_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${PRELIGHT}" | jq -c '.')"
assert_eq "preflight_contract" "inputs" '["plan_json"]' "${preflight_inputs}"
preflight_outputs="$(yq -o=json '.on.workflow_call.outputs | keys | sort' "${PRELIGHT}" | jq -c '.')"
assert_eq "preflight_contract" "outputs" '["network_access_policy_json","portainer_automation_allowed_cidrs","runner_label"]' "${preflight_outputs}"

infra_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${INFRA}" | jq -c '.')"
assert_eq "infra_contract" "inputs" '["network_access_policy_json","plan_json","runner_label"]' "${infra_inputs}"

ansible_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${ANSIBLE}" | jq -c '.')"
assert_eq "ansible_contract" "inputs" '["plan_json","runner_label"]' "${ansible_inputs}"

portainer_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${PORTAINER}" | jq -c '.')"
assert_eq "portainer_contract" "inputs" '["network_access_policy_json","plan_json","runner_label"]' "${portainer_inputs}"

inventory_upload_name="$(yq -r '.jobs."inventory-handover".steps[] | select(.uses == "actions/upload-artifact@v4") | .with.name' "${INFRA}")"
inventory_upload_path="$(yq -r '.jobs."inventory-handover".steps[] | select(.uses == "actions/upload-artifact@v4") | .with.path' "${INFRA}")"
assert_eq "inventory_contract" "upload_name" "inventory-ci" "${inventory_upload_name}"
assert_eq "inventory_contract" "upload_path" "inventory-ci.yml" "${inventory_upload_path}"

inventory_render_output="$(yq -r '.jobs."inventory-handover".steps[] | select(.run != null and .env.OUTPUT_FILE != null) | .env.OUTPUT_FILE' "${INFRA}" | head -n1)"
assert_eq "inventory_contract" "render_output" "inventory-ci.yml" "${inventory_render_output}"

infra_download_jobs="$(job_ids_with_step_uses "${INFRA}" "actions/download-artifact@v4")"
ansible_download_jobs="$(job_ids_with_step_uses "${ANSIBLE}" "actions/download-artifact@v4")"
portainer_download_jobs="$(job_ids_with_step_uses "${PORTAINER}" "actions/download-artifact@v4")"
assert_eq "inventory_contract" "infra_download_jobs" '["network-preflight-ssh"]' "${infra_download_jobs}"
assert_eq "inventory_contract" "ansible_download_jobs" '["ansible-bootstrap","host-sync"]' "${ansible_download_jobs}"
assert_eq "inventory_contract" "portainer_download_jobs" '["config-sync"]' "${portainer_download_jobs}"

network_policy_needs="$(yq -o=json '.jobs."network-policy-sync".needs' "${PRELIGHT}" | jq -c '.')"
assert_array_contains "preflight_gating" "network_policy_sync.needs" "stacks-sha-trust" "${network_policy_needs}"
network_policy_if="$(yq -r '.jobs."network-policy-sync".if' "${PRELIGHT}")"
assert_contains_text "preflight_gating" "network_policy_sync.if" "needs.stacks-sha-trust.result == 'success'" "${network_policy_if}"

portainer_needs="$(yq -o=json '.jobs."portainer-apply".needs' "${PORTAINER}" | jq -c '.')"
assert_array_contains "portainer_gating" "portainer_apply.needs" "config-sync" "${portainer_needs}"
health_needs="$(yq -o=json '.jobs."health-gated-redeploy".needs' "${PORTAINER}" | jq -c '.')"
assert_array_contains "portainer_gating" "health_gated_redeploy.needs" "config-sync" "${health_needs}"
portainer_apply_if="$(yq -r '.jobs."portainer-apply".if' "${PORTAINER}")"
assert_contains_text "portainer_gating" "portainer_apply.if" "stage_config_sync != true" "${portainer_apply_if}"

stacks_sha_trust_if="$(yq -r '.jobs."stacks-sha-trust".if' "${PRELIGHT}")"
assert_contains_text "stacks_sha_trust" "if" "stage_host_sync == true" "${stacks_sha_trust_if}"
assert_contains_text "stacks_sha_trust" "if" "stage_portainer_apply == true" "${stacks_sha_trust_if}"
assert_contains_text "stacks_sha_trust" "if" "stage_config_sync == true" "${stacks_sha_trust_if}"
assert_contains_text "stacks_sha_trust" "if" "stage_health_gated_redeploy == true" "${stacks_sha_trust_if}"

planner_jobs="$(yq -o=json '.jobs | keys' "${PLANNER_VALIDATION}" | jq -c 'sort')"
assert_eq "planner_validation" "jobs" '["bootstrap-tools-smoke","planner-contract-tests","stacks-sha-trust","workflow-contracts"]' "${planner_jobs}"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_resolve_ci_plan.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_trigger_webhooks_with_gates.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_preflight_network_access.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_secret_validation.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_post_bootstrap_secret_check.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_portainer_apply.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_import_infisical_secrets.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_workflow_contracts.sh"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" "scripts/**"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" "scripts/**"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" ".gitmodules"

terraform_jobs="$(yq -o=json '.jobs | keys' "${TERRAFORM_VALIDATION}" | jq -c 'sort')"
assert_eq "terraform_validation" "jobs" '["terraform-fmt","terraform-validate","tfc-speculative-plan"]' "${terraform_jobs}"
tfc_directory="$(yq -r '.jobs."tfc-speculative-plan".steps[] | select(.uses == "hashicorp/tfc-workflows-github/actions/upload-configuration@v1.0.0") | .with.directory' "${TERRAFORM_VALIDATION}")"
assert_eq "terraform_validation" "tfc_directory" "terraform/infra" "${tfc_directory}"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "pull_request" ".gitmodules"

ansible_jobs="$(yq -o=json '.jobs | keys' "${ANSIBLE_VALIDATION}" | jq -c 'sort')"
assert_eq "ansible_validation" "jobs" '["ansible-validate"]' "${ansible_jobs}"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "ansible_validation" "${ANSIBLE_VALIDATION}" "pull_request" ".gitmodules"

planner_dispatch_present="$(yq -o=json '.on | has("workflow_dispatch")' "${PLANNER_VALIDATION}" | jq -c '.')"
terraform_dispatch_present="$(yq -o=json '.on | has("workflow_dispatch")' "${TERRAFORM_VALIDATION}" | jq -c '.')"
ansible_dispatch_present="$(yq -o=json '.on | has("workflow_dispatch")' "${ANSIBLE_VALIDATION}" | jq -c '.')"
lint_dispatch_present="$(yq -o=json '.on | has("workflow_dispatch")' "${LINT}" | jq -c '.')"
assert_eq "validation_dispatch" "planner" "false" "${planner_dispatch_present}"
assert_eq "validation_dispatch" "terraform" "false" "${terraform_dispatch_present}"
assert_eq "validation_dispatch" "ansible" "false" "${ansible_dispatch_present}"
assert_eq "validation_dispatch" "lint" "false" "${lint_dispatch_present}"

lint_push_docs="$(yq -o=json '.on.push.paths' "${LINT}" | jq -e 'index("docs/**") != null' >/dev/null && echo true || echo false)"
lint_push_readme="$(yq -o=json '.on.push.paths' "${LINT}" | jq -e 'index("README.md") != null' >/dev/null && echo true || echo false)"
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
