#!/usr/bin/env bash

set -euo pipefail

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

infra_workspace_changed="false"
portainer_workspace_changed="false"
ansible_changed="false"
stacks_gitlink_changed="false"
stacks_sha=""

declare -a changed_tf_roots=()
declare -a tfc_matrix_rows=()

append_tf_root() {
  changed_tf_roots+=("$1")
}

append_tfc_workspace() {
  local workspace_key="$1"
  local config_directory="$2"
  tfc_matrix_rows+=("{\"workspace_key\":\"${workspace_key}\",\"config_directory\":\"${config_directory}\"}")
}

derive_flags_from_changed_files() {
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
    derive_flags_from_changed_files "${changed_files}"
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

# Portainer no longer runs speculative Terraform Cloud plans in CI.
# Local validate still runs via terraform-validate for terraform/portainer-root.

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

echo "infra_workspace_changed=${infra_workspace_changed}" >> "${GITHUB_OUTPUT}"
echo "portainer_workspace_changed=${portainer_workspace_changed}" >> "${GITHUB_OUTPUT}"
echo "ansible_changed=${ansible_changed}" >> "${GITHUB_OUTPUT}"
echo "stacks_gitlink_changed=${stacks_gitlink_changed}" >> "${GITHUB_OUTPUT}"
echo "stacks_sha=${stacks_sha}" >> "${GITHUB_OUTPUT}"
echo "changed_tf_roots_json=${changed_tf_roots_json}" >> "${GITHUB_OUTPUT}"
echo "tfc_workspace_matrix_json=${tfc_workspace_matrix_json}" >> "${GITHUB_OUTPUT}"
