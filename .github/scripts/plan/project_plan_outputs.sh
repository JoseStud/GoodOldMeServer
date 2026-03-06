#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <meta>"
  exit 1
fi

mode="$1"
if [[ "${mode}" != "meta" ]]; then
  echo "Unsupported projection mode: ${mode}"
  exit 1
fi

: "${PLAN_JSON:?PLAN_JSON is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

if ! jq -e . >/dev/null <<<"${PLAN_JSON}"; then
  echo "PLAN_JSON is not valid JSON."
  exit 1
fi

emit_output() {
  local key="$1"
  local value="$2"
  echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
}

require_field() {
  local jq_expr="$1"
  local field_name="$2"
  if ! jq -e "${jq_expr}" >/dev/null <<<"${PLAN_JSON}"; then
    echo "Missing or invalid field in PLAN_JSON: ${field_name}"
    exit 1
  fi
}

as_output_bool() {
  local jq_expr="$1"
  jq -r "${jq_expr} | if . then \"true\" else \"false\" end" <<<"${PLAN_JSON}"
}

as_output_string() {
  local jq_expr="$1"
  jq -r "${jq_expr}" <<<"${PLAN_JSON}"
}

plan_schema_version="$(jq -r '.plan_schema_version // ""' <<<"${PLAN_JSON}")"
if [[ "${plan_schema_version}" != "ci-plan-v1" ]]; then
  echo "Unsupported plan_schema_version '${plan_schema_version}'. Expected 'ci-plan-v1'."
  exit 1
fi

plan_mode="$(jq -r '.mode // ""' <<<"${PLAN_JSON}")"
if [[ "${plan_mode}" != "${mode}" ]]; then
  echo "PLAN_JSON mode '${plan_mode}' does not match requested projection mode '${mode}'."
  exit 1
fi

require_field '.meta | type == "object"' ".meta"
require_field '.meta.stages | type == "object"' ".meta.stages"

require_field '.meta.run_infra_apply | type == "boolean"' ".meta.run_infra_apply"
require_field '.meta.run_ansible_bootstrap | type == "boolean"' ".meta.run_ansible_bootstrap"
require_field '.meta.run_portainer_apply | type == "boolean"' ".meta.run_portainer_apply"
require_field '.meta.run_host_sync | type == "boolean"' ".meta.run_host_sync"
require_field '.meta.run_config_sync | type == "boolean"' ".meta.run_config_sync"
require_field '.meta.run_health_redeploy | type == "boolean"' ".meta.run_health_redeploy"
require_field '.meta.has_work | type == "boolean"' ".meta.has_work"
require_field '.meta.stacks_sha | type == "string"' ".meta.stacks_sha"
require_field '.meta.reason | type == "string"' ".meta.reason"

require_field '.meta.stages.stage_cloud_runner_guard | type == "boolean"' ".meta.stages.stage_cloud_runner_guard"
require_field '.meta.stages.stage_secret_validation | type == "boolean"' ".meta.stages.stage_secret_validation"
require_field '.meta.stages.stage_network_policy_sync | type == "boolean"' ".meta.stages.stage_network_policy_sync"
require_field '.meta.stages.stage_infra_apply | type == "boolean"' ".meta.stages.stage_infra_apply"
require_field '.meta.stages.stage_inventory_handover | type == "boolean"' ".meta.stages.stage_inventory_handover"
require_field '.meta.stages.stage_network_preflight_ssh | type == "boolean"' ".meta.stages.stage_network_preflight_ssh"
require_field '.meta.stages.stage_ansible_bootstrap | type == "boolean"' ".meta.stages.stage_ansible_bootstrap"
require_field '.meta.stages.stage_host_sync | type == "boolean"' ".meta.stages.stage_host_sync"
require_field '.meta.stages.stage_post_bootstrap_secret_check | type == "boolean"' ".meta.stages.stage_post_bootstrap_secret_check"
require_field '.meta.stages.stage_portainer_api_preflight | type == "boolean"' ".meta.stages.stage_portainer_api_preflight"
require_field '.meta.stages.stage_portainer_apply | type == "boolean"' ".meta.stages.stage_portainer_apply"
require_field '.meta.stages.stage_config_sync | type == "boolean"' ".meta.stages.stage_config_sync"
require_field '.meta.stages.stage_health_gated_redeploy | type == "boolean"' ".meta.stages.stage_health_gated_redeploy"

emit_output "run_infra_apply" "$(as_output_bool '.meta.run_infra_apply')"
emit_output "run_ansible_bootstrap" "$(as_output_bool '.meta.run_ansible_bootstrap')"
emit_output "run_portainer_apply" "$(as_output_bool '.meta.run_portainer_apply')"
emit_output "run_host_sync" "$(as_output_bool '.meta.run_host_sync')"
emit_output "run_config_sync" "$(as_output_bool '.meta.run_config_sync')"
emit_output "run_health_redeploy" "$(as_output_bool '.meta.run_health_redeploy')"
emit_output "has_work" "$(as_output_bool '.meta.has_work')"
emit_output "stacks_sha" "$(as_output_string '.meta.stacks_sha')"
emit_output "reason" "$(as_output_string '.meta.reason')"
emit_output "stage_cloud_runner_guard" "$(as_output_bool '.meta.stages.stage_cloud_runner_guard')"
emit_output "stage_secret_validation" "$(as_output_bool '.meta.stages.stage_secret_validation')"
emit_output "stage_network_policy_sync" "$(as_output_bool '.meta.stages.stage_network_policy_sync')"
emit_output "stage_infra_apply" "$(as_output_bool '.meta.stages.stage_infra_apply')"
emit_output "stage_inventory_handover" "$(as_output_bool '.meta.stages.stage_inventory_handover')"
emit_output "stage_network_preflight_ssh" "$(as_output_bool '.meta.stages.stage_network_preflight_ssh')"
emit_output "stage_ansible_bootstrap" "$(as_output_bool '.meta.stages.stage_ansible_bootstrap')"
emit_output "stage_host_sync" "$(as_output_bool '.meta.stages.stage_host_sync')"
emit_output "stage_post_bootstrap_secret_check" "$(as_output_bool '.meta.stages.stage_post_bootstrap_secret_check')"
emit_output "stage_portainer_api_preflight" "$(as_output_bool '.meta.stages.stage_portainer_api_preflight')"
emit_output "stage_portainer_apply" "$(as_output_bool '.meta.stages.stage_portainer_apply')"
emit_output "stage_config_sync" "$(as_output_bool '.meta.stages.stage_config_sync')"
emit_output "stage_health_gated_redeploy" "$(as_output_bool '.meta.stages.stage_health_gated_redeploy')"
