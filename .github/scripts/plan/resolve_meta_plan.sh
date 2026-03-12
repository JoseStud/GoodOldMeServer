#!/usr/bin/env bash
# Meta-mode plan resolver: computes orchestrator execution plan from push
# or repository_dispatch events.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/workflow_common.sh"

# Compute a comma-separated list of Ansible phase tags for a push_ansible_only
# event by mapping changed role paths to their corresponding phase tags.
# Returns an empty string when a full bootstrap is required (ambiguous changes,
# first push, or changes outside recognised role directories).
compute_ansible_tags_for_push() {
  local push_before="${PUSH_BEFORE:-}"
  local push_sha="${PUSH_SHA:-}"
  local null_sha="0000000000000000000000000000000000000000"

  # Cannot compute a diff — fall back to full bootstrap.
  if [[ -z "${push_before}" || "${push_before}" == "${null_sha}" || -z "${push_sha}" ]]; then
    echo ""
    return
  fi

  local changed_files
  changed_files="$(git diff --name-only "${push_before}" "${push_sha}" 2>&1)" || {
    echo "Warning: git diff failed (falling back to full bootstrap): ${changed_files}" >&2
    echo ""
    return
  }

  if [[ -z "${changed_files}" ]]; then
    echo ""
    return
  fi

  # Any change outside ansible/roles/ (playbooks, group_vars, host_vars,
  # requirements, etc.) has ambiguous phase impact — run full bootstrap.
  if echo "${changed_files}" | grep -qvE '^ansible/roles/'; then
    echo ""
    return
  fi

  local phases=()
  if echo "${changed_files}" | grep -qE '^ansible/roles/(system_user|storage)/'; then
    phases+=("phase1_base")
  fi
  if echo "${changed_files}" | grep -qE '^ansible/roles/docker/'; then
    phases+=("phase2_docker")
  fi
  if echo "${changed_files}" | grep -qE '^ansible/roles/tailscale/'; then
    phases+=("phase3_tailscale")
  fi
  if echo "${changed_files}" | grep -qE '^ansible/roles/glusterfs/'; then
    phases+=("phase4_glusterfs")
  fi
  if echo "${changed_files}" | grep -qE '^ansible/roles/swarm/'; then
    phases+=("phase5_swarm")
  fi
  if echo "${changed_files}" | grep -qE '^ansible/roles/portainer_bootstrap/'; then
    phases+=("phase6_portainer")
  fi
  if echo "${changed_files}" | grep -qE '^ansible/roles/runtime_sync/'; then
    phases+=("phase7_runtime_sync")
  fi

  if [[ ${#phases[@]} -eq 0 ]]; then
    # Changed files are in ansible/roles/ but no recognised phase mapping —
    # fall back to full bootstrap.
    echo ""
    return
  fi

  local IFS=","
  echo "${phases[*]}"
}

resolve_meta_mode() {
  run_infra_apply="false"
  run_ansible_bootstrap="false"
  run_portainer_apply="false"
  run_host_sync="false"
  run_config_sync="false"
  run_health_redeploy="false"
  ansible_tags=""
  stacks_sha=""
  reason=""

  if [[ "${EVENT_NAME}" == "push" || "${EVENT_NAME}" == "push_ansible_only" || "${EVENT_NAME}" == "workflow_dispatch" || "${EVENT_NAME}" == "dispatch_ansible_only" ]]; then
    # Push planning no longer does per-path impact detection. Any eligible
    # infra-repo push runs the full infra-side reconcile path pinned to the
    # current stacks gitlink recorded in this repo.
    stacks_sha="$(git rev-parse HEAD:stacks 2>/dev/null || true)"
    if [[ -z "${stacks_sha}" ]]; then
      echo "Failed to resolve stacks gitlink SHA from HEAD:stacks for push event."
      exit 1
    fi

    # push_ansible_only and dispatch_ansible_only are synthetic event names set by
    # ansible-orchestrator.yml for pushes/dispatches that only touch ansible/**
    # or .ansible-lint.  They skip the expensive TFC infra-apply stage but still
    # run Ansible bootstrap + Portainer reconciliation.
    if [[ "${EVENT_NAME}" == "push" || "${EVENT_NAME}" == "workflow_dispatch" ]]; then
      run_infra_apply="true"
      run_ansible_bootstrap="true"
      run_portainer_apply="true"
    else
      # push_ansible_only / dispatch_ansible_only
      run_infra_apply="false"
      run_ansible_bootstrap="true"
      run_portainer_apply="true"
      if [[ "${EVENT_NAME}" == "push_ansible_only" ]]; then
        ansible_tags="$(compute_ansible_tags_for_push)"
      fi
    fi

    if [[ "${EVENT_NAME}" == "push" || "${EVENT_NAME}" == "push_ansible_only" ]]; then
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
    echo "Unsupported EVENT_NAME for meta mode: ${EVENT_NAME}. Expected push, push_ansible_only, workflow_dispatch, dispatch_ansible_only, or repository_dispatch."
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

  if [[ -n "${stacks_sha}" ]] && ! is_valid_sha "${stacks_sha}"; then
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
      --arg ansible_tags "${ansible_tags}" \
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
          ansible_tags: $ansible_tags,
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
