#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${TFC_TOKEN:?TFC_TOKEN is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"
: "${TFC_WORKSPACE_PORTAINER:?TFC_WORKSPACE_PORTAINER is required}"

workspace_url="https://app.terraform.io/api/v2/organizations/${TFC_ORGANIZATION}/workspaces/${TFC_WORKSPACE_PORTAINER}"

echo "Portainer apply debug context:"
echo "  organization=${TFC_ORGANIZATION}"
echo "  workspace=${TFC_WORKSPACE_PORTAINER}"
echo "  workspace_url=${workspace_url}"
echo "  stacks_sha=${STACKS_SHA:-<unset>}"
echo "  shadow_mode=$(to_bool "${SHADOW_MODE:-false}")"
echo "  terraform_version=$(terraform version -json | jq -r '.terraform_version')"

workspace_json="$(
  curl -sSfL \
    -H "Authorization: Bearer ${TFC_TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    "${workspace_url}"
)"

echo "Terraform Cloud workspace attributes:"
jq '{
  id: .data.id,
  name: .data.attributes.name,
  operations: .data.attributes.operations,
  execution_mode: .data.attributes["execution-mode"],
  terraform_version: .data.attributes["terraform-version"],
  auto_apply: .data.attributes["auto-apply"],
  locked: .data.attributes.locked,
  vcs_repo_identifier: (.data.attributes["vcs-repo"].identifier // null),
  working_directory: .data.attributes["working-directory"]
}' <<<"${workspace_json}"
