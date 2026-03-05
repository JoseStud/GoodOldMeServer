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

validate_sha() {
  local sha="${1:-}"
  if [[ -z "${sha}" || "${sha}" == "null" ]]; then
    echo "repository_dispatch payload must include non-empty client_payload.stacks_sha."
    exit 1
  fi
  if ! [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid stacks_sha: '${sha}' (must be 40-char lowercase hex)."
    exit 1
  fi
}

validate_schema_version() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "repository_dispatch payload must include client_payload.schema_version."
    exit 1
  fi
  if [[ "${value}" != "v2" ]]; then
    echo "Unsupported dispatch schema_version '${value}'. Expected 'v2'."
    exit 1
  fi
}

validate_stack_csv() {
  local csv="${1:-}"
  if [[ -z "${csv}" || "${csv}" == "null" ]]; then
    return
  fi
  if ! [[ "${csv}" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]]; then
    echo "Invalid stack CSV: '${csv}' (expected: stack-a,stack-b)."
    exit 1
  fi
}

validate_paths_csv() {
  local csv="${1:-}"
  if [[ -z "${csv}" || "${csv}" == "null" ]]; then
    return
  fi
  if [[ "${csv}" =~ [[:space:]] || "${csv}" == *",,"* || "${csv}" == ,* || "${csv}" == *, ]]; then
    echo "Invalid changed_paths CSV: '${csv}'."
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
    structural-change|manual-refresh|content-change|infra-repo-push|infra-reconcile|portainer-reconcile|manual-dispatch|no-op)
      ;;
    *)
      echo "Invalid reason '${reason}'."
      echo "Allowed: structural-change, manual-refresh, content-change, infra-repo-push, infra-reconcile, portainer-reconcile, manual-dispatch, no-op"
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

  case "${value,,}" in
    true|false|1|0|yes|no)
      ;;
    *)
      echo "Invalid structural_change '${value}'."
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
validate_sha "${PAYLOAD_STACKS_SHA:-}"
validate_stack_csv "${PAYLOAD_CHANGED_STACKS:-}"
validate_stack_csv "${PAYLOAD_CONFIG_STACKS:-}"
validate_paths_csv "${PAYLOAD_CHANGED_PATHS:-}"
validate_reason "${PAYLOAD_REASON:-}"
validate_structural_change "${PAYLOAD_STRUCTURAL_CHANGE:-}"
validate_source_repo "${PAYLOAD_SOURCE_REPO:-}"
validate_source_run_id "${PAYLOAD_SOURCE_RUN_ID:-}"

echo "repository_dispatch payload validation passed for mode ${mode}."
