#!/usr/bin/env bash

set -euo pipefail

: "${TFC_TOKEN:?TFC_TOKEN is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"
: "${TFC_WORKSPACE:?TFC_WORKSPACE is required}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

workspace_json="$(
  curl -sSfL \
    -H "Authorization: Bearer ${TFC_TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    "https://app.terraform.io/api/v2/organizations/${TFC_ORGANIZATION}/workspaces/${TFC_WORKSPACE}"
)"

# jq's `//` treats `false` as "missing", so default only when the field is null.
operations_flag="$(jq -r 'if .data.attributes.operations == null then "true" else (.data.attributes.operations | tostring) end' <<<"${workspace_json}")"
execution_mode="$(jq -r '.data.attributes["execution-mode"] // "unknown"' <<<"${workspace_json}")"

if [[ "${operations_flag}" != "false" ]]; then
  echo "Workspace '${TFC_WORKSPACE}' is not configured for local operations."
  echo "Expected operations=false, got operations=${operations_flag} (execution-mode=${execution_mode})."
  exit 1
fi

echo "Workspace '${TFC_WORKSPACE}' is configured for local operations (operations=false)."
