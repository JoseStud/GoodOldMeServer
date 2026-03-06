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

  if [[ "${value}" != "v4" ]]; then
    echo "Unsupported dispatch schema_version '${value}'. Expected 'v4'."
    exit 1
  fi
}

validate_stack_array_json() {
  local field_name="$1"
  local json_value="${2:-}"

  if [[ -z "${json_value}" || "${json_value}" == "null" ]]; then
    echo "repository_dispatch payload must include client_payload.${field_name} (JSON array)."
    exit 1
  fi

  if ! jq -e 'type == "array" and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]*$"))' <<<"${json_value}" >/dev/null; then
    echo "Invalid ${field_name}: expected JSON array of stack names (e.g. [\"gateway\",\"auth\"])."
    exit 1
  fi
}

validate_paths_array_json() {
  local field_name="$1"
  local json_value="${2:-}"

  if [[ -z "${json_value}" || "${json_value}" == "null" ]]; then
    return
  fi

  if ! jq -e 'type == "array" and all(.[]; type == "string" and (length > 0) and (contains(",") | not))' <<<"${json_value}" >/dev/null; then
    echo "Invalid ${field_name}: expected JSON array of non-empty path strings without commas."
    exit 1
  fi
}

validate_reason() {
  local reason="${1:-}"

  if [[ -z "${reason}" || "${reason}" == "null" ]]; then
    echo "repository_dispatch payload must include non-empty client_payload.reason."
    exit 1
  fi

  case "${reason}" in
    structural-change|manual-refresh|content-change)
      ;;
    *)
      echo "Invalid reason '${reason}'."
      echo "Allowed: structural-change, manual-refresh, content-change"
      exit 1
      ;;
  esac
}

validate_structural_change() {
  local value="${1:-}"

  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "repository_dispatch payload must include client_payload.structural_change."
    exit 1
  fi

  case "${value}" in
    true|false)
      ;;
    *)
      echo "Invalid structural_change '${value}'. Expected boolean true/false."
      exit 1
      ;;
  esac
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

validate_schema_version "${PAYLOAD_SCHEMA_VERSION:-}"
validate_sha "stacks_sha" "${PAYLOAD_STACKS_SHA:-}"
validate_sha "source_sha" "${PAYLOAD_SOURCE_SHA:-}"
validate_stack_array_json "changed_stacks" "${PAYLOAD_CHANGED_STACKS_JSON:-}"
validate_stack_array_json "host_sync_stacks" "${PAYLOAD_HOST_SYNC_STACKS_JSON:-}"
validate_stack_array_json "config_stacks" "${PAYLOAD_CONFIG_STACKS_JSON:-}"
validate_paths_array_json "changed_paths" "${PAYLOAD_CHANGED_PATHS_JSON:-}"
validate_reason "${PAYLOAD_REASON:-}"
validate_structural_change "${PAYLOAD_STRUCTURAL_CHANGE:-}"
validate_source_repo "${PAYLOAD_SOURCE_REPO:-}"
validate_source_run_id "${PAYLOAD_SOURCE_RUN_ID:-}"

echo "repository_dispatch payload validation passed for mode ${mode}."
