#!/usr/bin/env bash

set -euo pipefail

: "${NETWORK_ACCESS_POLICY_JSON:?NETWORK_ACCESS_POLICY_JSON is required}"
: "${TFC_TOKEN:?TFC_TOKEN is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"
: "${TFC_WORKSPACE_INFRA:?TFC_WORKSPACE_INFRA is required}"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

TFC_API_URL="${TFC_API_URL:-https://app.terraform.io/api/v2}"
TFC_POLICY_VAR_KEY="${TFC_POLICY_VAR_KEY:-TF_VAR_network_access_policy}"

api_get() {
  local url="$1"
  curl -sSfL \
    -H "Authorization: Bearer ${TFC_TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    "${url}"
}

api_write() {
  local method="$1"
  local url="$2"
  local payload="$3"
  curl -sSfL \
    -X "${method}" \
    -H "Authorization: Bearer ${TFC_TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    -d "${payload}" \
    "${url}"
}

policy_json="$(jq -cS '.' <<<"${NETWORK_ACCESS_POLICY_JSON}")"
portainer_cidrs_csv="$(jq -r '.portainer_api.source_ranges | join(",")' <<<"${policy_json}")"

workspace_json="$(api_get "${TFC_API_URL%/}/organizations/${TFC_ORGANIZATION}/workspaces/${TFC_WORKSPACE_INFRA}")"
workspace_id="$(jq -r '.data.id // empty' <<<"${workspace_json}")"
if [[ -z "${workspace_id}" ]]; then
  echo "Failed to resolve workspace id for ${TFC_WORKSPACE_INFRA}."
  exit 1
fi

vars_json="$(api_get "${TFC_API_URL%/}/workspaces/${workspace_id}/vars?page[size]=200")"
existing_var_id="$(jq -r --arg key "${TFC_POLICY_VAR_KEY}" '.data[] | select(.attributes.key == $key and .attributes.category == "env") | .id' <<<"${vars_json}" | head -n1)"

payload="$(
  jq -cn \
    --arg key "${TFC_POLICY_VAR_KEY}" \
    --arg value "${policy_json}" \
    '{
      data: {
        type: "vars",
        attributes: {
          key: $key,
          value: $value,
          description: "Managed by meta-pipeline network policy sync",
          category: "env",
          hcl: false,
          sensitive: false
        }
      }
    }'
)"

if [[ -n "${existing_var_id}" ]]; then
  api_write "PATCH" "${TFC_API_URL%/}/vars/${existing_var_id}" "${payload}" >/dev/null
else
  api_write "POST" "${TFC_API_URL%/}/workspaces/${workspace_id}/vars" "${payload}" >/dev/null
fi

vars_after_json="$(api_get "${TFC_API_URL%/}/workspaces/${workspace_id}/vars?page[size]=200")"
tfc_policy_raw="$(jq -r --arg key "${TFC_POLICY_VAR_KEY}" '.data[] | select(.attributes.key == $key and .attributes.category == "env") | .attributes.value // empty' <<<"${vars_after_json}" | head -n1)"
if [[ -z "${tfc_policy_raw}" ]]; then
  echo "Failed to read back ${TFC_POLICY_VAR_KEY} from Terraform Cloud."
  exit 1
fi

tfc_policy_json="$(jq -cS '.' <<<"${tfc_policy_raw}")"
if [[ "${tfc_policy_json}" != "${policy_json}" ]]; then
  echo "Terraform Cloud variable verification failed."
  echo "Expected: ${policy_json}"
  echo "Actual:   ${tfc_policy_json}"
  exit 1
fi

infisical secrets set \
  PORTAINER_AUTOMATION_ALLOWED_CIDRS="${portainer_cidrs_csv}" \
  --env=prod \
  --path="/stacks/management" \
  >/dev/null

infisical_cidrs="$(
  infisical run \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --env=prod \
    --path=/stacks/management \
    -- bash -lc 'printf %s "${PORTAINER_AUTOMATION_ALLOWED_CIDRS:-}"'
)"

if [[ "${infisical_cidrs}" != "${portainer_cidrs_csv}" ]]; then
  echo "Infisical secret verification failed."
  echo "Expected: ${portainer_cidrs_csv}"
  echo "Actual:   ${infisical_cidrs}"
  exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "network_access_policy_json=${policy_json}"
    echo "portainer_automation_allowed_cidrs=${portainer_cidrs_csv}"
  } >>"${GITHUB_OUTPUT}"
fi

echo "Network access policy sync completed and verified."
