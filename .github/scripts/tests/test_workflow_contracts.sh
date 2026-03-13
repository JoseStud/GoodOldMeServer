#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ORCHESTRATOR="${ROOT_DIR}/.github/workflows/orchestrator.yml"
PRELIGHT="${ROOT_DIR}/.github/workflows/reusable-orch-preflight.yml"
INFRA="${ROOT_DIR}/.github/workflows/reusable-orch-infra.yml"
ANSIBLE="${ROOT_DIR}/.github/workflows/reusable-orch-ansible.yml"
PORTAINER="${ROOT_DIR}/.github/workflows/reusable-orch-portainer.yml"
PLANNER_VALIDATION="${ROOT_DIR}/.github/workflows/validate-planner-contracts.yml"
TERRAFORM_VALIDATION="${ROOT_DIR}/.github/workflows/validate-terraform.yml"
ANSIBLE_VALIDATION="${ROOT_DIR}/.github/workflows/validate-ansible.yml"
LINT="${ROOT_DIR}/.github/workflows/lint-github-actions.yml"
REUSABLE="${ROOT_DIR}/.github/workflows/reusable-resolve-plan.yml"
BOOTSTRAP_QUERY_TOOLS="${ROOT_DIR}/.github/actions/bootstrap-query-tools/action.yml"

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
    fail "${case_name}: unexpected ${file}"
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

assert_job_runs_on() {
  local case_name="$1"
  local file="$2"
  local job_id="$3"
  local expected="$4"
  local actual

  actual="$(yq -r ".jobs.\"${job_id}\".\"runs-on\" // \"\"" "${file}")"
  assert_eq "${case_name}" "${job_id}.runs-on" "${expected}" "${actual}"
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

assert_workflow_env_value() {
  local case_name="$1"
  local file="$2"
  local key="$3"
  local expected="$4"
  local actual

  actual="$(yq -r ".env.\"${key}\" // \"\"" "${file}")"
  assert_eq "${case_name}" "env.${key}" "${expected}" "${actual}"
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

assert_push_includes_main() {
  local case_name="$1"
  local file="$2"
  local push_branches
  local push_branches_ignore
  local includes_main

  push_branches="$(yq -o=json '.on.push.branches // null' "${file}" | jq -c '.')"
  push_branches_ignore="$(yq -o=json '.on.push."branches-ignore" // []' "${file}" | jq -c '.')"

  includes_main="$(
    jq -cn \
      --argjson branches "${push_branches}" \
      --argjson branches_ignore "${push_branches_ignore}" '
        if ($branches | type) == "array" then
          ($branches | index("main")) != null
        else
          ($branches_ignore | index("main")) == null
        end
      '
  )"

  assert_eq "${case_name}" "push_includes_main" "true" "${includes_main}"
}

assert_push_does_not_ignore_main() {
  local case_name="$1"
  local file="$2"
  local ignores_main

  ignores_main="$(
    yq -o=json '.on.push."branches-ignore" // []' "${file}" \
      | jq -c 'index("main") != null'
  )"

  assert_eq "${case_name}" "push_ignores_main" "false" "${ignores_main}"
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

runner_jobs_with_local_actions() {
  local file="$1"
  local runner_expr="$2"

  yq -o=json '.jobs' "${file}" | jq -r --arg runner_expr "${runner_expr}" '
    to_entries[]
    | select((.value["runs-on"] // "") == $runner_expr)
    | select((.value.steps // []) | any((.uses // "") | startswith("./.github/actions/")))
    | .key
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
  "${BOOTSTRAP_QUERY_TOOLS}"; do
  assert_file_exists "active_workflows" "${workflow}"
done

assert_file_absent "retired_bootstrap_action" "${ROOT_DIR}/.github/actions/bootstrap-tools/action.yml"
assert_file_absent "retired_ansible_orchestrator" "${ROOT_DIR}/.github/workflows/ansible-orchestrator.yml"
assert_file_absent "retired_infra_orchestrator" "${ROOT_DIR}/.github/workflows/infra-orchestrator.yml"

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
assert_eq "orchestrator_dispatch" "workflow_dispatch" "true" "$(yq -o=json '.on | has("workflow_dispatch")' "${ORCHESTRATOR}" | jq -c '.')"
assert_eq "orchestrator_dispatch" "workflow_call" "null" "$(yq -o=json '.on.workflow_call // null' "${ORCHESTRATOR}" | jq -c '.')"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" "stacks"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" ".gitmodules"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" "ansible/**"
assert_trigger_path_contains "orchestrator_dispatch" "${ORCHESTRATOR}" "push" ".ansible-lint"

reusable_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${REUSABLE}" | jq -c '.')"
assert_eq "resolve_plan_contract" "inputs" '["dispatch_payload_json","dispatch_reason","dispatch_source_repo","dispatch_source_run_id","dispatch_source_sha","dispatch_stacks_sha","push_before","push_sha","source_event_name"]' "${reusable_inputs}"
if rg -n 'dorny/paths-filter|META_FILTER_APPLIED|META_INFRA_CHANGED|META_ANSIBLE_CHANGED|META_PORTAINER_CHANGED|path-filters\.yml|Detect changed paths' "${REUSABLE}" >/dev/null; then
  fail "resolve_plan_contract: found retired path-detection references"
else
  pass "resolve_plan_contract: no retired path-detection references"
fi

preflight_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${PRELIGHT}" | jq -c '.')"
assert_eq "preflight_contract" "inputs" '["plan_json"]' "${preflight_inputs}"
preflight_outputs="$(yq -o=json '.on.workflow_call.outputs | keys | sort' "${PRELIGHT}" | jq -c '.')"
assert_eq "preflight_contract" "outputs" '["network_access_policy_json","runner_label"]' "${preflight_outputs}"
assert_workflow_env_value "preflight_contract" "${PRELIGHT}" "INFISICAL_MACHINE_IDENTITY_ID" '${{ vars.INFISICAL_MACHINE_IDENTITY_ID }}'
assert_workflow_env_value "preflight_contract" "${PRELIGHT}" "INFISICAL_PROJECT_ID" '${{ vars.INFISICAL_PROJECT_ID }}'
assert_job_runs_on "preflight_contract" "${PRELIGHT}" "secret-validation" '${{ needs.cloud-runner-guard.outputs.runner_label }}'
secret_validation_needs="$(yq -o=json '.jobs."secret-validation".needs' "${PRELIGHT}" | jq -c '.')"
assert_eq "preflight_contract" "secret-validation.needs" '["validate-plan-json","cloud-runner-guard"]' "${secret_validation_needs}"

infra_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${INFRA}" | jq -c '.')"
assert_eq "infra_contract" "inputs" '["network_access_policy_json","plan_json","runner_label"]' "${infra_inputs}"

ansible_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${ANSIBLE}" | jq -c '.')"
assert_eq "ansible_contract" "inputs" '["plan_json","runner_label"]' "${ansible_inputs}"
assert_workflow_env_value "ansible_contract" "${ANSIBLE}" "INFISICAL_MACHINE_IDENTITY_ID" '${{ vars.INFISICAL_MACHINE_IDENTITY_ID }}'
assert_workflow_env_value "ansible_contract" "${ANSIBLE}" "INFISICAL_PROJECT_ID" '${{ vars.INFISICAL_PROJECT_ID }}'

portainer_inputs="$(yq -o=json '.on.workflow_call.inputs | keys | sort' "${PORTAINER}" | jq -c '.')"
assert_eq "portainer_contract" "inputs" '["network_access_policy_json","plan_json","runner_label"]' "${portainer_inputs}"
assert_workflow_env_value "portainer_contract" "${PORTAINER}" "INFISICAL_MACHINE_IDENTITY_ID" '${{ vars.INFISICAL_MACHINE_IDENTITY_ID }}'
assert_workflow_env_value "portainer_contract" "${PORTAINER}" "INFISICAL_PROJECT_ID" '${{ vars.INFISICAL_PROJECT_ID }}'
assert_job_runs_on "portainer_contract" "${PORTAINER}" "post-bootstrap-secret-check" '${{ inputs.runner_label }}'

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
config_sync_if="$(yq -r '.jobs."config-sync".if' "${PORTAINER}")"
assert_contains_text "portainer_gating" "config_sync.if" "meta.stages.stage_config_sync" "${config_sync_if}"
portainer_apply_if="$(yq -r '.jobs."portainer-apply".if' "${PORTAINER}")"
assert_contains_text "portainer_gating" "portainer_apply.if" "meta.stages.stage_portainer_apply" "${portainer_apply_if}"
assert_contains_text "portainer_gating" "portainer_apply.if" "needs.portainer-api-preflight.result == 'success'" "${portainer_apply_if}"
assert_contains_text "portainer_gating" "portainer_apply.if" "needs.config-sync.result == 'success'" "${portainer_apply_if}"

health_redeploy_if="$(yq -r '.jobs."health-gated-redeploy".if' "${PORTAINER}")"
assert_contains_text "portainer_gating" "health_gated_redeploy.if" "needs.config-sync.result == 'skipped'" "${health_redeploy_if}"

stacks_sha_trust_if="$(yq -r '.jobs."stacks-sha-trust".if' "${PRELIGHT}")"
assert_contains_text "stacks_sha_trust" "if" "meta.stacks_sha != ''" "${stacks_sha_trust_if}"

# Contract: plan_json validation is centralized in preflight.
# Downstream workflows must NOT include validate-plan-json.
infra_has_validate="$(yq -o=json '.jobs | has("validate-plan-json")' "${INFRA}")"
assert_eq "centralized_validation" "infra_no_validate_plan_json" "false" "${infra_has_validate}"

ansible_has_validate="$(yq -o=json '.jobs | has("validate-plan-json")' "${ANSIBLE}")"
assert_eq "centralized_validation" "ansible_no_validate_plan_json" "false" "${ansible_has_validate}"

portainer_has_validate="$(yq -o=json '.jobs | has("validate-plan-json")' "${PORTAINER}")"
assert_eq "centralized_validation" "portainer_no_validate_plan_json" "false" "${portainer_has_validate}"

preflight_has_validate="$(yq -o=json '.jobs | has("validate-plan-json")' "${PRELIGHT}")"
assert_eq "centralized_validation" "preflight_has_validate_plan_json" "true" "${preflight_has_validate}"

# Contract: validation workflow must NOT wait for signals; preflight MUST.
planner_wait="$(yq -r '.jobs."stacks-sha-trust".steps[] | select(.run != null and (.run | test("verify_trusted_stacks_sha"))) | .env.WAIT_FOR_SUCCESS // ""' "${PLANNER_VALIDATION}")"
assert_eq "stacks_sha_trust_wait" "planner_no_wait" "" "${planner_wait}"

preflight_wait="$(yq -r '.jobs."stacks-sha-trust".steps[] | select(.run != null and (.run | test("verify_trusted_stacks_sha"))) | .env.WAIT_FOR_SUCCESS // ""' "${PRELIGHT}")"
assert_eq "stacks_sha_trust_wait" "preflight_waits" "true" "${preflight_wait}"

planner_jobs="$(yq -o=json '.jobs | keys' "${PLANNER_VALIDATION}" | jq -c 'sort')"
assert_eq "planner_validation" "jobs" '["bootstrap-query-tools-smoke","planner-contract-tests","stacks-sha-trust","workflow-contracts"]' "${planner_jobs}"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "python3 -m pytest .github/scripts/plan/tests/ -v"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_trigger_webhooks_with_gates.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_preflight_network_access.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_sync_network_access_policy.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_secret_validation.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_post_bootstrap_secret_check.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_portainer_apply.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_import_infisical_secrets.sh"
assert_run_present "planner_validation" "${PLANNER_VALIDATION}" "bash .github/scripts/tests/test_workflow_contracts.sh"
assert_push_includes_main "planner_validation" "${PLANNER_VALIDATION}"
assert_push_does_not_ignore_main "planner_validation" "${PLANNER_VALIDATION}"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" "scripts/**"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" "scripts/**"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "planner_validation" "${PLANNER_VALIDATION}" "pull_request" ".gitmodules"

bootstrap_query_inputs="$(yq -o=json '.inputs | keys | sort' "${BOOTSTRAP_QUERY_TOOLS}" | jq -c '.')"
assert_eq "bootstrap_query_contract" "inputs" '["install_jq","install_yq","jq_sha256","jq_version","tool_versions_lock_path","yq_sha256","yq_version"]' "${bootstrap_query_inputs}"

assert_no_regex_match "retired_bootstrap_refs" '\./\.github/actions/bootstrap-tools|install_infisical:|install_netcat:|install_gomplate:' .github/workflows

preflight_runner_local_actions="$(runner_jobs_with_local_actions "${PRELIGHT}" '${{ needs.cloud-runner-guard.outputs.runner_label }}')"
assert_eq "runner_contract" "preflight_local_actions" "" "${preflight_runner_local_actions}"
infra_runner_local_actions="$(runner_jobs_with_local_actions "${INFRA}" '${{ inputs.runner_label }}')"
assert_eq "runner_contract" "infra_local_actions" "" "${infra_runner_local_actions}"
ansible_runner_local_actions="$(runner_jobs_with_local_actions "${ANSIBLE}" '${{ inputs.runner_label }}')"
assert_eq "runner_contract" "ansible_local_actions" "" "${ansible_runner_local_actions}"
portainer_runner_local_actions="$(runner_jobs_with_local_actions "${PORTAINER}" '${{ inputs.runner_label }}')"
assert_eq "runner_contract" "portainer_local_actions" "" "${portainer_runner_local_actions}"

terraform_jobs="$(yq -o=json '.jobs | keys' "${TERRAFORM_VALIDATION}" | jq -c 'sort')"
assert_eq "terraform_validation" "jobs" '["cloud-runner-guard","portainer-live-plan","terraform-fmt","terraform-validate","tfc-speculative-plan"]' "${terraform_jobs}"
terraform_permissions_id_token="$(yq -r '.permissions."id-token" // ""' "${TERRAFORM_VALIDATION}")"
assert_eq "terraform_validation" "permissions.id-token" "write" "${terraform_permissions_id_token}"
assert_job_runs_on "terraform_validation" "${TERRAFORM_VALIDATION}" "portainer-live-plan" '${{ needs.cloud-runner-guard.outputs.runner_label }}'
assert_job_needs "terraform_validation" "${TERRAFORM_VALIDATION}" "portainer-live-plan" '["terraform-validate","cloud-runner-guard"]'
tfc_directory="$(yq -r '.jobs."tfc-speculative-plan".steps[] | select(.uses == "hashicorp/tfc-workflows-github/actions/upload-configuration@v1.0.0") | .with.directory' "${TERRAFORM_VALIDATION}")"
assert_eq "terraform_validation" "tfc_directory" "terraform/infra" "${tfc_directory}"
portainer_live_plan_shadow_mode="$(yq -r '.jobs."portainer-live-plan".steps[] | select(.run == ".github/scripts/stages/portainer_apply.sh") | .env.SHADOW_MODE // ""' "${TERRAFORM_VALIDATION}")"
assert_eq "terraform_validation" "portainer_live_plan.shadow_mode" "true" "${portainer_live_plan_shadow_mode}"
assert_push_includes_main "terraform_validation" "${TERRAFORM_VALIDATION}"
assert_push_does_not_ignore_main "terraform_validation" "${TERRAFORM_VALIDATION}"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "push" "stacks"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "push" ".gitmodules"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "pull_request" "stacks"
assert_trigger_path_contains "terraform_validation" "${TERRAFORM_VALIDATION}" "pull_request" ".gitmodules"

portainer_apply_tfc_token="$(yq -r '.jobs."portainer-apply".steps[] | select(.run == ".github/scripts/stages/portainer_apply.sh") | .env.TFC_TOKEN // ""' "${PORTAINER}")"
assert_eq "portainer_contract" "portainer_apply.env.TFC_TOKEN" '${{ secrets.TFC_TOKEN }}' "${portainer_apply_tfc_token}"

ansible_jobs="$(yq -o=json '.jobs | keys' "${ANSIBLE_VALIDATION}" | jq -c 'sort')"
assert_eq "ansible_validation" "jobs" '["ansible-validate"]' "${ansible_jobs}"
assert_push_includes_main "ansible_validation" "${ANSIBLE_VALIDATION}"
assert_push_does_not_ignore_main "ansible_validation" "${ANSIBLE_VALIDATION}"
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
