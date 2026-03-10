#!/usr/bin/env bash
# Meta-mode plan resolver: computes orchestrator execution plan from push
# or repository_dispatch events.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/workflow_common.sh"

resolve_meta_mode() {
  run_infra_apply="false"
  run_ansible_bootstrap="false"
  run_portainer_apply="false"
  run_host_sync="false"
  run_config_sync="false"
  run_health_redeploy="false"
  stacks_sha=""
  reason=""

  if [[ "${EVENT_NAME}" == "push" || "${EVENT_NAME}" == "workflow_dispatch" ]]; then
    # Push planning no longer does per-path impact detection. Any eligible
    # infra-repo push runs the full infra-side reconcile path pinned to the
    # current stacks gitlink recorded in this repo.
    stacks_sha="$(git rev-parse HEAD:stacks 2>/dev/null || true)"
    if [[ -z "${stacks_sha}" ]]; then
      echo "Failed to resolve stacks gitlink SHA from HEAD:stacks for push event."
      exit 1
    fi

    # When ANSIBLE_ONLY_MODE is set, skip the expensive TFC apply and only run
    # Ansible bootstrap + Portainer reconciliation.  The ansible-orchestrator
    # workflow sets this for pushes that only touch ansible/** or .ansible-lint.
    if [[ "$(to_bool "${ANSIBLE_ONLY_MODE:-false}")" == "true" ]]; then
      run_infra_apply="false"
      run_ansible_bootstrap="true"
      run_portainer_apply="true"
    else
      run_infra_apply="true"
      run_ansible_bootstrap="true"
      run_portainer_apply="true"
    fi

    if [[ "${EVENT_NAME}" == "push" ]]; then
      reason="infra-repo-push"
    else
      reason="manual-dispatch"
    fi
  elif [[ "${EVENT_NAME}" == "repository_dispatch" ]]; then
    # Guard retained for direct script invocation (e.g. tests) where the
    # caller has not already validated.  In CI the reusable-resolve-plan
    # workflow validates in a dedicated step and passes
    # VALIDATE_DISPATCH_CONTRACT=false to avoid double-validation.
    if [[ "$(to_bool "${VALIDATE_DISPATCH_CONTRACT:-true}")" == "true" ]]; then
      .github/scripts/plan/validate_dispatch_payload.sh "meta"
    fi

    stacks_sha="$(normalize_nullable "${PAYLOAD_STACKS_SHA:-}")"
    reason="$(normalize_nullable "${PAYLOAD_REASON:-}")"

    # Any stacks dispatch now runs the full reconcile path regardless of the
    # payload, with no stack-targeting support.
    run_portainer_apply="true"
    run_host_sync="true"
    run_config_sync="true"
    run_health_redeploy="true"
  else
    echo "Unsupported EVENT_NAME for meta mode: ${EVENT_NAME}. Expected push, workflow_dispatch, or repository_dispatch."
    exit 1
  fi

  if [[ -z "${reason}" ]]; then
    if [[ "${run_infra_apply}" == "true" ]]; then
      reason="infra-reconcile"
    elif [[ "${run_portainer_apply}" == "true" ]]; then
      reason="portainer-reconcile"
    elif [[ "${run_host_sync}" == "true" ]]; then
      reason="host-runtime-sync"
    elif [[ "${run_health_redeploy}" == "true" ]]; then
      reason="content-change"
    else
      reason="no-op"
    fi
  fi

  if [[ -n "${stacks_sha}" && ! "${stacks_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid stacks SHA: ${stacks_sha}"
    exit 1
  fi

  has_work="false"
  if [[ "${run_infra_apply}" == "true" || "${run_ansible_bootstrap}" == "true" || "${run_portainer_apply}" == "true" || "${run_host_sync}" == "true" || "${run_config_sync}" == "true" || "${run_health_redeploy}" == "true" ]]; then
    has_work="true"
  fi

  stage_cloud_runner_guard="${has_work}"
  stage_secret_validation="${has_work}"
  stage_network_policy_sync="${has_work}"
  stage_infra_apply="${run_infra_apply}"

  stage_inventory_handover="false"
  if [[ "${run_ansible_bootstrap}" == "true" || "${run_host_sync}" == "true" || "${run_config_sync}" == "true" ]]; then
    stage_inventory_handover="true"
  fi

  stage_network_preflight_ssh="${stage_inventory_handover}"
  stage_ansible_bootstrap="${run_ansible_bootstrap}"
  stage_host_sync="false"
  if [[ "${run_host_sync}" == "true" && "${run_ansible_bootstrap}" != "true" ]]; then
    stage_host_sync="true"
  fi
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
      --arg run_host_sync "${run_host_sync}" \
      --arg run_config_sync "${run_config_sync}" \
      --arg run_health_redeploy "${run_health_redeploy}" \
      --arg has_work "${has_work}" \
      --arg stacks_sha "${stacks_sha}" \
      --arg reason "${reason}" \
      --arg stage_cloud_runner_guard "${stage_cloud_runner_guard}" \
      --arg stage_secret_validation "${stage_secret_validation}" \
      --arg stage_network_policy_sync "${stage_network_policy_sync}" \
      --arg stage_infra_apply "${stage_infra_apply}" \
      --arg stage_inventory_handover "${stage_inventory_handover}" \
      --arg stage_network_preflight_ssh "${stage_network_preflight_ssh}" \
      --arg stage_ansible_bootstrap "${stage_ansible_bootstrap}" \
      --arg stage_host_sync "${stage_host_sync}" \
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
          run_host_sync: ($run_host_sync == "true"),
          run_config_sync: ($run_config_sync == "true"),
          run_health_redeploy: ($run_health_redeploy == "true"),
          has_work: ($has_work == "true"),
          stacks_sha: $stacks_sha,
          reason: $reason,
          stages: {
            stage_cloud_runner_guard: ($stage_cloud_runner_guard == "true"),
            stage_secret_validation: ($stage_secret_validation == "true"),
            stage_network_policy_sync: ($stage_network_policy_sync == "true"),
            stage_infra_apply: ($stage_infra_apply == "true"),
            stage_inventory_handover: ($stage_inventory_handover == "true"),
            stage_network_preflight_ssh: ($stage_network_preflight_ssh == "true"),
            stage_ansible_bootstrap: ($stage_ansible_bootstrap == "true"),
            stage_host_sync: ($stage_host_sync == "true"),
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
