#!/usr/bin/env bash
# IAC-mode plan resolver: computes validation impact from push,
# pull_request, or workflow_dispatch events.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/workflow_common.sh"

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
      --arg plan_schema_version "${PLAN_SCHEMA_VERSION}" \
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
        plan_schema_version: $plan_schema_version,
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
}
