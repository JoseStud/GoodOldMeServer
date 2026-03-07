#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

setup_infisical

portainer_api_url="$(fetch_infisical_secret /management PORTAINER_API_URL)"
portainer_api_key="$(fetch_infisical_secret /management PORTAINER_API_KEY)"
portainer_admin_password_hash="$(fetch_infisical_secret /stacks/management PORTAINER_ADMIN_PASSWORD_HASH)"

assert_https_url_value "PORTAINER_API_URL" "${portainer_api_url}"
assert_nonplaceholder_value "PORTAINER_API_KEY" "${portainer_api_key}"
assert_bcrypt_hash_value "PORTAINER_ADMIN_PASSWORD_HASH" "${portainer_admin_password_hash}"
