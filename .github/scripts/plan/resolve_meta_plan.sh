#!/usr/bin/env bash
# Meta-mode plan resolver: computes orchestrator execution plan from push,
# repository_dispatch, workflow_dispatch, or workflow_call events.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/workflow_common.sh"

derive_meta_push_flags_from_changed_files() {
  local changed_files="$1"

  if grep -Eq '^terraform/(infra|oci|gcp)/' <<<"${changed_files}"; then
    run_infra_apply="true"
  fi

  if grep -Eq '(^ansible/|^\.ansible-lint$)' <<<"${changed_files}"; then
    run_ansible_bootstrap="true"
  fi

  if grep -Eq '^(terraform/portainer/|terraform/portainer-root/)' <<<"${changed_files}"; then
    run_portainer_apply="true"
  fi
}

resolve_meta_mode() {
  run_infra_apply="false"
  run_ansible_bootstrap="false"
  run_portainer_apply="false"
  stacks_sha=""
  changed_stacks=""
  config_stacks=""
  structural_change="false"
  reason=""
  changed_paths=""

  if [[ "${EVENT_NAME}" == "push" ]]; then
    before="${PUSH_BEFORE:-}"
    after="${PUSH_SHA:-${GITHUB_SHA:-HEAD}}"

    if [[ "${before}" =~ ^0+$ || -z "${before}" ]]; then
      changed_files="$(git show --name-only --pretty='' "${after}" || true)"
    else
      changed_files="$(git diff --name-only "${before}" "${after}" || true)"
    fi

    changed_paths="$(normalize_csv "$(echo "${changed_files}" | paste -sd, -)")"

    if [[ "$(to_bool "${META_FILTER_APPLIED:-false}")" == "true" ]]; then
      run_infra_apply="$(to_bool "${META_INFRA_CHANGED:-false}")"
      run_ansible_bootstrap="$(to_bool "${META_ANSIBLE_CHANGED:-false}")"
      run_portainer_apply="$(to_bool "${META_PORTAINER_CHANGED:-false}")"
    else
      derive_meta_push_flags_from_changed_files "${changed_files}"
    fi

    if [[ "${run_infra_apply}" == "true" ]]; then
      run_ansible_bootstrap="true"
      run_portainer_apply="true"
    fi

    if [[ "${run_ansible_bootstrap}" == "true" ]]; then
      run_portainer_apply="true"
    fi

    reason="infra-repo-push"
  elif [[ "${EVENT_NAME}" == "repository_dispatch" ]]; then
    if [[ "$(to_bool "${VALIDATE_DISPATCH_CONTRACT:-true}")" == "true" ]]; then
      .github/scripts/plan/validate_dispatch_payload.sh "meta"
    fi

    stacks_sha="$(normalize_nullable "${PAYLOAD_STACKS_SHA:-}")"

    if [[ -n "${PAYLOAD_CHANGED_STACKS_JSON:-}" && "${PAYLOAD_CHANGED_STACKS_JSON:-}" != "null" ]]; then
      changed_stacks="$(normalize_json_array_to_csv "${PAYLOAD_CHANGED_STACKS_JSON}" '^[a-z0-9][a-z0-9-]*$' "PAYLOAD_CHANGED_STACKS_JSON")"
    else
      changed_stacks="$(normalize_csv "${PAYLOAD_CHANGED_STACKS:-}")"
    fi

    if [[ -n "${PAYLOAD_CONFIG_STACKS_JSON:-}" && "${PAYLOAD_CONFIG_STACKS_JSON:-}" != "null" ]]; then
      config_stacks="$(normalize_json_array_to_csv "${PAYLOAD_CONFIG_STACKS_JSON}" '^[a-z0-9][a-z0-9-]*$' "PAYLOAD_CONFIG_STACKS_JSON")"
    else
      config_stacks="$(normalize_csv "${PAYLOAD_CONFIG_STACKS:-}")"
    fi

    structural_change="$(to_bool "${PAYLOAD_STRUCTURAL_CHANGE:-}")"
    reason="$(normalize_nullable "${PAYLOAD_REASON:-}")"

    if [[ -n "${PAYLOAD_CHANGED_PATHS_JSON:-}" && "${PAYLOAD_CHANGED_PATHS_JSON:-}" != "null" ]]; then
      changed_paths="$(normalize_json_array_to_csv "${PAYLOAD_CHANGED_PATHS_JSON}" '^[^,\r\n]+$' "PAYLOAD_CHANGED_PATHS_JSON")"
    else
      changed_paths="$(normalize_csv "${PAYLOAD_CHANGED_PATHS:-}")"
    fi

    if [[ "${structural_change}" == "true" || "${reason}" == "structural-change" || "${reason}" == "manual-refresh" ]]; then
      run_portainer_apply="true"
    fi
  elif [[ "${EVENT_NAME}" == "workflow_dispatch" || "${EVENT_NAME}" == "workflow_call" ]]; then
    run_infra_apply="$(to_bool "${INPUT_RUN_INFRA:-}")"
    run_ansible_bootstrap="$(to_bool "${INPUT_RUN_ANSIBLE:-}")"
    run_portainer_apply="$(to_bool "${INPUT_RUN_PORTAINER:-}")"
    stacks_sha="$(normalize_nullable "${INPUT_STACKS_SHA:-}")"

    if [[ -n "${INPUT_CHANGED_STACKS_JSON:-}" && "${INPUT_CHANGED_STACKS_JSON:-}" != "null" ]]; then
      changed_stacks="$(normalize_json_array_to_csv "${INPUT_CHANGED_STACKS_JSON}" '^[a-z0-9][a-z0-9-]*$' "INPUT_CHANGED_STACKS_JSON")"
    else
      changed_stacks="$(normalize_csv "${INPUT_CHANGED_STACKS:-}")"
    fi

    if [[ -n "${INPUT_CONFIG_STACKS_JSON:-}" && "${INPUT_CONFIG_STACKS_JSON:-}" != "null" ]]; then
      config_stacks="$(normalize_json_array_to_csv "${INPUT_CONFIG_STACKS_JSON}" '^[a-z0-9][a-z0-9-]*$' "INPUT_CONFIG_STACKS_JSON")"
    else
      config_stacks="$(normalize_csv "${INPUT_CONFIG_STACKS:-}")"
    fi

    structural_change="$(to_bool "${INPUT_STRUCTURAL_CHANGE:-}")"
    reason="$(normalize_nullable "${INPUT_REASON:-}")"

    if [[ -n "${INPUT_CHANGED_PATHS_JSON:-}" && "${INPUT_CHANGED_PATHS_JSON:-}" != "null" ]]; then
      changed_paths="$(normalize_json_array_to_csv "${INPUT_CHANGED_PATHS_JSON}" '^[^,\r\n]+$' "INPUT_CHANGED_PATHS_JSON")"
    else
      changed_paths="$(normalize_csv "${INPUT_CHANGED_PATHS:-}")"
    fi
  fi

  if [[ -n "${config_stacks}" ]]; then
    changed_stacks="$(normalize_csv "${changed_stacks},${config_stacks}")"
  fi

  run_config_sync="false"
  if [[ -n "${config_stacks}" ]]; then
    run_config_sync="true"
  fi

  run_health_redeploy="false"
  if [[ -n "${changed_stacks}" ]]; then
    run_health_redeploy="true"
  fi

  if [[ -z "${reason}" ]]; then
    if [[ "${run_infra_apply}" == "true" ]]; then
      reason="infra-reconcile"
    elif [[ "${run_portainer_apply}" == "true" ]]; then
      reason="portainer-reconcile"
    elif [[ "${run_health_redeploy}" == "true" ]]; then
      reason="content-change"
    else
      reason="no-op"
    fi
  fi

  resolve_stacks_sha_from_head="$(to_bool "${RESOLVE_STACKS_SHA_FROM_HEAD:-false}")"
  if [[ "${resolve_stacks_sha_from_head}" == "true" && -z "${stacks_sha}" ]]; then
    stacks_sha="$(git rev-parse HEAD:stacks 2>/dev/null || true)"
  fi

  if [[ -n "${stacks_sha}" && ! "${stacks_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid stacks SHA: ${stacks_sha}"
    exit 1
  fi

  has_work="false"
  if [[ "${run_infra_apply}" == "true" || "${run_ansible_bootstrap}" == "true" || "${run_portainer_apply}" == "true" || "${run_config_sync}" == "true" || "${run_health_redeploy}" == "true" ]]; then
    has_work="true"
  fi

  stage_cloud_runner_guard="${has_work}"
  stage_secret_validation="${has_work}"
  stage_network_policy_sync="${has_work}"
  stage_infra_apply="${run_infra_apply}"

  stage_inventory_handover="false"
  if [[ "${run_ansible_bootstrap}" == "true" || "${run_config_sync}" == "true" ]]; then
    stage_inventory_handover="true"
  fi

  stage_network_preflight_ssh="${stage_inventory_handover}"
  stage_ansible_bootstrap="${run_ansible_bootstrap}"
  stage_post_bootstrap_secret_check="${run_portainer_apply}"

  stage_portainer_api_preflight="false"
  if [[ "${run_portainer_apply}" == "true" || "${run_health_redeploy}" == "true" ]]; then
    stage_portainer_api_preflight="true"
  fi

  stage_portainer_apply="${run_portainer_apply}"
  stage_config_sync="${run_config_sync}"
  stage_health_gated_redeploy="${run_health_redeploy}"

  plan_json="$(
    jq -cn \
      --arg plan_schema_version "${PLAN_SCHEMA_VERSION}" \
      --arg mode "${CI_PLAN_MODE}" \
      --arg event_name "${EVENT_NAME}" \
      --arg run_infra_apply "${run_infra_apply}" \
      --arg run_ansible_bootstrap "${run_ansible_bootstrap}" \
      --arg run_portainer_apply "${run_portainer_apply}" \
      --arg run_config_sync "${run_config_sync}" \
      --arg run_health_redeploy "${run_health_redeploy}" \
      --arg has_work "${has_work}" \
      --arg stacks_sha "${stacks_sha}" \
      --arg changed_stacks "${changed_stacks}" \
      --arg config_stacks "${config_stacks}" \
      --arg structural_change "${structural_change}" \
      --arg reason "${reason}" \
      --arg changed_paths "${changed_paths}" \
      --arg stage_cloud_runner_guard "${stage_cloud_runner_guard}" \
      --arg stage_secret_validation "${stage_secret_validation}" \
      --arg stage_network_policy_sync "${stage_network_policy_sync}" \
      --arg stage_infra_apply "${stage_infra_apply}" \
      --arg stage_inventory_handover "${stage_inventory_handover}" \
      --arg stage_network_preflight_ssh "${stage_network_preflight_ssh}" \
      --arg stage_ansible_bootstrap "${stage_ansible_bootstrap}" \
      --arg stage_post_bootstrap_secret_check "${stage_post_bootstrap_secret_check}" \
      --arg stage_portainer_api_preflight "${stage_portainer_api_preflight}" \
      --arg stage_portainer_apply "${stage_portainer_apply}" \
      --arg stage_config_sync "${stage_config_sync}" \
      --arg stage_health_gated_redeploy "${stage_health_gated_redeploy}" \
      '{
        plan_schema_version: $plan_schema_version,
        mode: $mode,
        event_name: $event_name,
        meta: {
          run_infra_apply: ($run_infra_apply == "true"),
          run_ansible_bootstrap: ($run_ansible_bootstrap == "true"),
          run_portainer_apply: ($run_portainer_apply == "true"),
          run_config_sync: ($run_config_sync == "true"),
          run_health_redeploy: ($run_health_redeploy == "true"),
          has_work: ($has_work == "true"),
          stacks_sha: $stacks_sha,
          changed_stacks: $changed_stacks,
          config_stacks: $config_stacks,
          structural_change: ($structural_change == "true"),
          reason: $reason,
          changed_paths: $changed_paths,
          stages: {
            stage_cloud_runner_guard: ($stage_cloud_runner_guard == "true"),
            stage_secret_validation: ($stage_secret_validation == "true"),
            stage_network_policy_sync: ($stage_network_policy_sync == "true"),
            stage_infra_apply: ($stage_infra_apply == "true"),
            stage_inventory_handover: ($stage_inventory_handover == "true"),
            stage_network_preflight_ssh: ($stage_network_preflight_ssh == "true"),
            stage_ansible_bootstrap: ($stage_ansible_bootstrap == "true"),
            stage_post_bootstrap_secret_check: ($stage_post_bootstrap_secret_check == "true"),
            stage_portainer_api_preflight: ($stage_portainer_api_preflight == "true"),
            stage_portainer_apply: ($stage_portainer_apply == "true"),
            stage_config_sync: ($stage_config_sync == "true"),
            stage_health_gated_redeploy: ($stage_health_gated_redeploy == "true")
          }
        }
      }'
  )"

  emit_output "plan_json" "${plan_json}"
}
