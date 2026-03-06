#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <meta>"
  exit 1
fi

mode="$1"
if [[ "${mode}" != "meta" ]]; then
  echo "Unknown validation mode: ${mode}"
  exit 1
fi

: "${EVENT_NAME:?EVENT_NAME is required}"

if [[ "${EVENT_NAME}" != "repository_dispatch" ]]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

validate_payload_shape() {
  local payload_json="${1:-}"
  local expected_keys actual_keys

  if [[ -z "${payload_json}" || "${payload_json}" == "null" ]]; then
    return
  fi

  if ! jq -e 'type == "object"' >/dev/null <<<"${payload_json}"; then
    echo "repository_dispatch payload must be a JSON object."
    exit 1
  fi

  expected_keys='["reason","schema_version","source_repo","source_run_id","source_sha","stacks_sha"]'
  actual_keys="$(jq -c 'keys | sort' <<<"${payload_json}")"
  if [[ "${actual_keys}" != "${expected_keys}" ]]; then
    echo "repository_dispatch payload must contain only: schema_version, stacks_sha, source_sha, source_repo, source_run_id, reason."
    exit 1
  fi
}

validate_sha() {
  local field_name="$1"
  local sha="${2:-}"

  if [[ -z "${sha}" || "${sha}" == "null" ]]; then
    echo "repository_dispatch payload must include non-empty client_payload.${field_name}."
    exit 1
  fi

  if ! [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid ${field_name}: '${sha}' (must be 40-char lowercase hex)."
    exit 1
  fi
}

validate_schema_version() {
  local value="${1:-}"

  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "repository_dispatch payload must include client_payload.schema_version."
    exit 1
  fi

  if [[ "${value}" != "v5" ]]; then
    echo "Unsupported dispatch schema_version '${value}'. Expected 'v5'."
    exit 1
  fi
}

validate_reason() {
  local reason="${1:-}"

  if [[ -z "${reason}" || "${reason}" == "null" ]]; then
    echo "repository_dispatch payload must include non-empty client_payload.reason."
    exit 1
  fi

  if [[ "${reason}" != "full-reconcile" ]]; then
    echo "Invalid reason '${reason}'. Expected 'full-reconcile'."
    exit 1
  fi
}

reject_removed_field() {
  local field_name="$1"
  local field_value="${2:-}"

  if [[ -n "${field_value}" && "${field_value}" != "null" ]]; then
    echo "repository_dispatch payload must not include removed client_payload.${field_name}."
    exit 1
  fi
}

validate_source_repo() {
  local value="${1:-}"

  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "repository_dispatch payload must include client_payload.source_repo."
    exit 1
  fi

  if ! [[ "${value}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid source_repo '${value}'. Expected 'owner/repo'."
    exit 1
  fi
}

validate_source_run_id() {
  local value="${1:-}"

  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "repository_dispatch payload must include client_payload.source_run_id."
    exit 1
  fi

  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "Invalid source_run_id '${value}'. Expected numeric run id."
    exit 1
  fi
}

validate_payload_shape "${PAYLOAD_JSON:-}"
validate_schema_version "${PAYLOAD_SCHEMA_VERSION:-}"
validate_sha "stacks_sha" "${PAYLOAD_STACKS_SHA:-}"
validate_sha "source_sha" "${PAYLOAD_SOURCE_SHA:-}"
validate_reason "${PAYLOAD_REASON:-}"
validate_source_repo "${PAYLOAD_SOURCE_REPO:-}"
validate_source_run_id "${PAYLOAD_SOURCE_RUN_ID:-}"
reject_removed_field "changed_stacks" "${PAYLOAD_CHANGED_STACKS:-}"
reject_removed_field "changed_stacks" "${PAYLOAD_CHANGED_STACKS_JSON:-}"
reject_removed_field "host_sync_stacks" "${PAYLOAD_HOST_SYNC_STACKS:-}"
reject_removed_field "host_sync_stacks" "${PAYLOAD_HOST_SYNC_STACKS_JSON:-}"
reject_removed_field "config_stacks" "${PAYLOAD_CONFIG_STACKS:-}"
reject_removed_field "config_stacks" "${PAYLOAD_CONFIG_STACKS_JSON:-}"
reject_removed_field "structural_change" "${PAYLOAD_STRUCTURAL_CHANGE:-}"
reject_removed_field "changed_paths" "${PAYLOAD_CHANGED_PATHS:-}"
reject_removed_field "changed_paths" "${PAYLOAD_CHANGED_PATHS_JSON:-}"

echo "repository_dispatch payload validation passed for mode ${mode}."
