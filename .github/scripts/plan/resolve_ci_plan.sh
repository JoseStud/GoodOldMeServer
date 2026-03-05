#!/usr/bin/env bash

set -euo pipefail

: "${CI_PLAN_MODE:?CI_PLAN_MODE is required}"
: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ "${CI_PLAN_MODE}" != "meta" && "${CI_PLAN_MODE}" != "iac" ]]; then
  echo "Unsupported CI_PLAN_MODE: ${CI_PLAN_MODE}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

emit_output() {
  local key="$1"
  local value="$2"
  echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
}

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

normalize_nullable() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo ""
    return
  fi
  echo "${value}"
}

normalize_csv() {
  local input="${1:-}"
  input="$(echo "${input}" | tr -d '\r')"
  if [[ -z "${input}" || "${input}" == "null" ]]; then
    echo ""
    return
  fi

  IFS=',' read -ra parts <<< "${input}"
  if [[ ${#parts[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  printf '%s\n' "${parts[@]}" \
    | awk '{$1=$1; print}' \
    | awk 'NF > 0' \
    | awk '!seen[$0]++' \
    | sort \
    | paste -sd, -
}

normalize_json_array_to_csv() {
  local input="${1:-}"
  local item_regex="${2:-.*}"
  local field_name="${3:-json_array}"

  if [[ -z "${input}" || "${input}" == "null" ]]; then
    echo ""
    return
  fi

  if ! jq -e --arg re "${item_regex}" '
      type == "array"
      and all(.[]; type == "string" and test($re))
    ' <<<"${input}" >/dev/null; then
    echo "Invalid ${field_name}: expected JSON array of strings matching regex '${item_regex}'."
    exit 1
  fi

  jq -r '.[]' <<<"${input}" \
    | awk '{$1=$1; print}' \
    | awk 'NF > 0' \
    | awk '!seen[$0]++' \
    | sort \
    | paste -sd, -
}

append_unique() {
  local value="$1"
  shift
  local -a current=("$@")
  local existing=""
  for existing in "${current[@]}"; do
    if [[ "${existing}" == "${value}" ]]; then
      return 1
    fi
  done
  return 0
}

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
  emit_output "run_infra_apply" "${run_infra_apply}"
  emit_output "run_ansible_bootstrap" "${run_ansible_bootstrap}"
  emit_output "run_portainer_apply" "${run_portainer_apply}"
  emit_output "run_config_sync" "${run_config_sync}"
  emit_output "run_health_redeploy" "${run_health_redeploy}"
  emit_output "has_work" "${has_work}"
  emit_output "stacks_sha" "${stacks_sha}"
  emit_output "changed_stacks" "${changed_stacks}"
  emit_output "config_stacks" "${config_stacks}"
  emit_output "structural_change" "${structural_change}"
  emit_output "reason" "${reason}"
  emit_output "changed_paths" "${changed_paths}"

  emit_output "stage_cloud_runner_guard" "${stage_cloud_runner_guard}"
  emit_output "stage_secret_validation" "${stage_secret_validation}"
  emit_output "stage_network_policy_sync" "${stage_network_policy_sync}"
  emit_output "stage_infra_apply" "${stage_infra_apply}"
  emit_output "stage_inventory_handover" "${stage_inventory_handover}"
  emit_output "stage_network_preflight_ssh" "${stage_network_preflight_ssh}"
  emit_output "stage_ansible_bootstrap" "${stage_ansible_bootstrap}"
  emit_output "stage_post_bootstrap_secret_check" "${stage_post_bootstrap_secret_check}"
  emit_output "stage_portainer_api_preflight" "${stage_portainer_api_preflight}"
  emit_output "stage_portainer_apply" "${stage_portainer_apply}"
  emit_output "stage_config_sync" "${stage_config_sync}"
  emit_output "stage_health_gated_redeploy" "${stage_health_gated_redeploy}"
}

resolve_iac_mode() {
  infra_workspace_changed="false"
  portainer_workspace_changed="false"
  ansible_changed="false"
  stacks_gitlink_changed="false"
  stacks_sha=""

  declare -a changed_tf_roots=()
  declare -a tfc_matrix_rows=()

  append_tf_root() {
    local root="$1"
    if append_unique "${root}" "${changed_tf_roots[@]}"; then
      changed_tf_roots+=("${root}")
    fi
  }

  append_tfc_workspace() {
    local workspace_key="$1"
    local config_directory="$2"
    tfc_matrix_rows+=("{\"workspace_key\":\"${workspace_key}\",\"config_directory\":\"${config_directory}\"}")
  }

  derive_iac_flags_from_changed_files() {
    local changed_files="$1"

    if grep -Eq '^terraform/(infra|oci|gcp)/' <<<"${changed_files}"; then
      infra_workspace_changed="true"
    fi

    if grep -Eq '^terraform/(portainer-root|portainer)/' <<<"${changed_files}"; then
      portainer_workspace_changed="true"
    fi

    if grep -Eq '(^ansible/|^\.ansible-lint$)' <<<"${changed_files}"; then
      ansible_changed="true"
    fi

    if grep -Eq '^stacks$' <<<"${changed_files}"; then
      stacks_gitlink_changed="true"
    fi

    if grep -Eq '^terraform/infra/' <<<"${changed_files}"; then
      append_tf_root "terraform/infra"
    fi
    if grep -Eq '^terraform/oci/' <<<"${changed_files}"; then
      append_tf_root "terraform/oci"
    fi
    if grep -Eq '^terraform/gcp/' <<<"${changed_files}"; then
      append_tf_root "terraform/gcp"
    fi
    if grep -Eq '^terraform/portainer-root/' <<<"${changed_files}"; then
      append_tf_root "terraform/portainer-root"
    fi
    if grep -Eq '^terraform/portainer/' <<<"${changed_files}"; then
      append_tf_root "terraform/portainer"
    fi
  }

  if [[ "${EVENT_NAME}" == "workflow_dispatch" ]]; then
    infra_workspace_changed="true"
    portainer_workspace_changed="true"
    ansible_changed="true"
    stacks_gitlink_changed="true"
    stacks_sha="$(git rev-parse HEAD:stacks 2>/dev/null || true)"

    changed_tf_roots=(
      "terraform/infra"
      "terraform/oci"
      "terraform/gcp"
      "terraform/portainer-root"
      "terraform/portainer"
    )
  else
    if [[ "${EVENT_NAME}" == "push" && "${PUSH_BEFORE_SHA:-}" =~ ^0+$ ]]; then
      changed_files="$(git show --name-only --pretty='' "${GITHUB_SHA_CURRENT:-HEAD}" || true)"
      derive_iac_flags_from_changed_files "${changed_files}"
    else
      infra_workspace_changed="$(to_bool "${IAC_WORKSPACE_INFRA:-false}")"
      portainer_workspace_changed="$(to_bool "${IAC_WORKSPACE_PORTAINER:-false}")"
      ansible_changed="$(to_bool "${IAC_ANSIBLE:-false}")"
      stacks_gitlink_changed="$(to_bool "${IAC_STACKS_GITLINK_CHANGED:-false}")"

      if [[ "$(to_bool "${IAC_TF_INFRA:-false}")" == "true" ]]; then
        append_tf_root "terraform/infra"
      fi
      if [[ "$(to_bool "${IAC_TF_OCI:-false}")" == "true" ]]; then
        append_tf_root "terraform/oci"
      fi
      if [[ "$(to_bool "${IAC_TF_GCP:-false}")" == "true" ]]; then
        append_tf_root "terraform/gcp"
      fi
      if [[ "$(to_bool "${IAC_TF_PORTAINER_ROOT:-false}")" == "true" ]]; then
        append_tf_root "terraform/portainer-root"
      fi
      if [[ "$(to_bool "${IAC_TF_PORTAINER:-false}")" == "true" ]]; then
        append_tf_root "terraform/portainer"
      fi
    fi

    if [[ "${stacks_gitlink_changed}" == "true" ]]; then
      stacks_sha="$(git rev-parse "${GITHUB_SHA_CURRENT:-HEAD}:stacks" 2>/dev/null || true)"
    fi
  fi

  if [[ "${infra_workspace_changed}" == "true" ]]; then
    append_tfc_workspace "infra" "terraform/infra"
  fi

  if (( ${#changed_tf_roots[@]} == 0 )); then
    changed_tf_roots_json='[]'
  else
    changed_tf_roots_json="$(printf '%s\n' "${changed_tf_roots[@]}" | jq -R . | jq -s -c .)"
  fi

  if (( ${#tfc_matrix_rows[@]} == 0 )); then
    tfc_workspace_matrix_json='[]'
  else
    tfc_workspace_matrix_json="$(printf '%s\n' "${tfc_matrix_rows[@]}" | jq -s -c .)"
  fi

  plan_json="$(
    jq -cn \
      --arg mode "${CI_PLAN_MODE}" \
      --arg event_name "${EVENT_NAME}" \
      --arg infra_workspace_changed "${infra_workspace_changed}" \
      --arg portainer_workspace_changed "${portainer_workspace_changed}" \
      --arg ansible_changed "${ansible_changed}" \
      --arg stacks_gitlink_changed "${stacks_gitlink_changed}" \
      --arg stacks_sha "${stacks_sha}" \
      --arg changed_tf_roots_json "${changed_tf_roots_json}" \
      --arg tfc_workspace_matrix_json "${tfc_workspace_matrix_json}" \
      '{
        mode: $mode,
        event_name: $event_name,
        iac: {
          infra_workspace_changed: ($infra_workspace_changed == "true"),
          portainer_workspace_changed: ($portainer_workspace_changed == "true"),
          ansible_changed: ($ansible_changed == "true"),
          stacks_gitlink_changed: ($stacks_gitlink_changed == "true"),
          stacks_sha: $stacks_sha,
          changed_tf_roots: ($changed_tf_roots_json | fromjson),
          tfc_workspace_matrix: ($tfc_workspace_matrix_json | fromjson)
        }
      }'
  )"

  emit_output "plan_json" "${plan_json}"
  emit_output "infra_workspace_changed" "${infra_workspace_changed}"
  emit_output "portainer_workspace_changed" "${portainer_workspace_changed}"
  emit_output "ansible_changed" "${ansible_changed}"
  emit_output "stacks_gitlink_changed" "${stacks_gitlink_changed}"
  emit_output "stacks_sha" "${stacks_sha}"
  emit_output "changed_tf_roots_json" "${changed_tf_roots_json}"
  emit_output "tfc_workspace_matrix_json" "${tfc_workspace_matrix_json}"
}

case "${CI_PLAN_MODE}" in
  meta)
    resolve_meta_mode
    ;;
  iac)
    resolve_iac_mode
    ;;
esac
