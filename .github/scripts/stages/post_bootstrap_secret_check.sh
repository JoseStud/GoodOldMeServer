#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

setup_infisical

portainer_admin_user="${PORTAINER_ADMIN_USER:-admin}"
portainer_api_url="$(fetch_infisical_secret /management PORTAINER_API_URL)"
portainer_api_key="$(fetch_infisical_secret /management PORTAINER_API_KEY)"
portainer_admin_password="$(fetch_infisical_secret /stacks/management PORTAINER_ADMIN_PASSWORD)"
portainer_admin_password_hash="$(fetch_infisical_secret /stacks/management PORTAINER_ADMIN_PASSWORD_HASH)"

assert_url_value "PORTAINER_API_URL" "${portainer_api_url}"
assert_nonplaceholder_value "PORTAINER_API_KEY" "${portainer_api_key}"
assert_nonplaceholder_value "PORTAINER_ADMIN_PASSWORD" "${portainer_admin_password}"
assert_bcrypt_hash_value "PORTAINER_ADMIN_PASSWORD_HASH" "${portainer_admin_password_hash}"

status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "X-API-Key: ${portainer_api_key}" \
  "${portainer_api_url%/}/system/status" || true)"

if [[ "${status}" == "200" ]]; then
  echo "Portainer API key secret is valid."
  exit 0
fi

if [[ "${status}" != "401" && "${status}" != "403" ]]; then
  echo "Portainer API key validation failed unexpectedly (HTTP ${status})."
  exit 1
fi

echo "Portainer API key secret is stale (HTTP ${status}); rotating terraform-managed token."

auth_payload="$(jq -nc \
  --arg username "${portainer_admin_user}" \
  --arg password "${portainer_admin_password}" \
  '{Username: $username, Password: $password}'
)"

auth_json="$(
  curl -sSf \
    -H "Content-Type: application/json" \
    -d "${auth_payload}" \
    "${portainer_api_url%/}/auth"
)"
jwt="$(jq -r '.jwt // empty' <<<"${auth_json}")"
if [[ -z "${jwt}" ]]; then
  echo "Failed to authenticate to Portainer API for token rotation."
  exit 1
fi

tokens_json="$(
  curl -sSf \
    -H "Authorization: Bearer ${jwt}" \
    "${portainer_api_url%/}/users/1/tokens"
)"

mapfile -t terraform_managed_token_ids < <(
  jq -r '.[] | select(.description == "terraform-managed") | .id' <<<"${tokens_json}"
)

for token_id in "${terraform_managed_token_ids[@]}"; do
  curl -sSf \
    -X DELETE \
    -H "Authorization: Bearer ${jwt}" \
    "${portainer_api_url%/}/users/1/tokens/${token_id}" >/dev/null
done

new_token_json="$(
  curl -sSf \
    -H "Authorization: Bearer ${jwt}" \
    -H "Content-Type: application/json" \
    -d '{"description":"terraform-managed"}' \
    "${portainer_api_url%/}/users/1/tokens"
)"
rotated_api_key="$(jq -r '.rawAPIKey // empty' <<<"${new_token_json}")"
if [[ -z "${rotated_api_key}" ]]; then
  echo "Portainer token rotation did not return a raw API key."
  exit 1
fi

infisical secrets set "PORTAINER_API_KEY=${rotated_api_key}" \
  --env=prod \
  --path=/management \
  --projectId="${INFISICAL_PROJECT_ID}" >/dev/null

rotated_status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "X-API-Key: ${rotated_api_key}" \
  "${portainer_api_url%/}/system/status" || true)"
if [[ "${rotated_status}" != "200" ]]; then
  echo "Rotated Portainer API key failed validation (HTTP ${rotated_status})."
  exit 1
fi

echo "Portainer API key rotated and written back to Infisical."
