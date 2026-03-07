#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/stages/secret_validation.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  local message="$1"
  echo "[PASS] ${message}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local message="$1"
  echo "[FAIL] ${message}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
  local case_name="$1"
  local pattern="$2"
  local file="$3"

  if grep -Fq -- "${pattern}" "${file}"; then
    pass "${case_name}: found '${pattern}'"
  else
    fail "${case_name}: missing '${pattern}'"
  fi
}

run_case() {
  local case_name="$1"
  shift
  local out_file="${TMP_DIR}/${case_name}.out"

  (
    set -euo pipefail
    "$@"
  ) >"${out_file}" 2>&1

  echo "${out_file}"
}

run_case_expect_fail() {
  local case_name="$1"
  shift
  local out_file="${TMP_DIR}/${case_name}.out"

  if (
    set -euo pipefail
    "$@"
  ) >"${out_file}" 2>&1; then
    fail "${case_name}: expected failure but script succeeded" >&2
  else
    pass "${case_name}: failed as expected" >&2
  fi

  echo "${out_file}"
}

BIN_DIR="${TMP_DIR}/bin"
FAKE_INFISICAL_ROOT="${TMP_DIR}/infisical"
mkdir -p "${BIN_DIR}" "${FAKE_INFISICAL_ROOT}"

cat > "${BIN_DIR}/infisical" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
if [[ -z "${command_name}" ]]; then
  echo "Missing infisical command" >&2
  exit 1
fi
shift

case "${command_name}" in
  login)
    exit 0
    ;;
  run)
    path=""
    while (($# > 0)); do
      case "$1" in
        --projectId=*|--env=*|--domain=*)
          shift
          ;;
        --projectId|--env|--domain)
          shift 2
          ;;
        --path=*)
          path="${1#*=}"
          shift
          ;;
        --path)
          path="$2"
          shift 2
          ;;
        --)
          shift
          break
          ;;
        *)
          echo "Unexpected infisical arg: $1" >&2
          exit 1
          ;;
      esac
    done

    env_file="${FAKE_INFISICAL_ROOT}${path}/env"
    if [[ -f "${env_file}" ]]; then
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        export "${line}"
      done < "${env_file}"
    fi

    exec "$@"
    ;;
  *)
    echo "Unsupported infisical command: ${command_name}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BIN_DIR}/infisical"

write_secret_file() {
  local path="$1"
  shift
  local target_dir="${FAKE_INFISICAL_ROOT}${path}"
  mkdir -p "${target_dir}"
  printf '%s\n' "$@" > "${target_dir}/env"
}

seed_common_stack_secrets() {
  write_secret_file /infrastructure \
    'BASE_DOMAIN=goodoldme.example' \
    'TZ=Etc/UTC' \
    'CLOUDFLARE_API_TOKEN=cf-token' \
    'TAILSCALE_AUTH_KEY=ts-auth'

  write_secret_file /stacks/gateway \
    'ACME_EMAIL=ops@example.org' \
    'DOCKER_SOCKET_PROXY_URL=tcp://socket-proxy:2375'

  write_secret_file /stacks/identity \
    'AUTHELIA_JWT_SECRET=jwt-secret' \
    'AUTHELIA_SESSION_SECRET=session-secret' \
    'POSTGRES_PASSWORD=pg-secret' \
    'AUTHELIA_NOTIFIER_SMTP_USERNAME=mailer@example.org' \
    'AUTHELIA_NOTIFIER_SMTP_PASSWORD=smtp-secret' \
    'AUTHELIA_NOTIFIER_SMTP_SENDER=Authelia <mailer@example.org>' \
    'AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET=oidc-hmac-secret' \
    'AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY=-----BEGIN_PRIVATE_KEY-----stub-----END_PRIVATE_KEY-----'

  write_secret_file /stacks/network \
    'VW_DB_PASS=vw-db-secret' \
    'VW_ADMIN_TOKEN=vw-admin-secret' \
    'PIHOLE_PASSWORD=pihole-secret'

  write_secret_file /stacks/observability \
    'GF_OIDC_CLIENT_ID=grafana' \
    'GF_OIDC_CLIENT_SECRET=oidc-client-secret' \
    'ALERTMANAGER_WEBHOOK_URL=https://hooks.example.org/alerts'

  write_secret_file /stacks/ai-interface \
    'ARCH_PC_IP=100.64.0.10'
}

seed_common_stack_secrets
write_secret_file /stacks/management \
  'HOMARR_SECRET_KEY=homarr-secret' \
  'PORTAINER_ADMIN_PASSWORD=portainer-admin-password'

bootstrap_case_out="$(run_case "bootstrap_allows_synced_allowlist_missing" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  INFISICAL_MACHINE_IDENTITY_ID=test-machine-id \
  INFISICAL_PROJECT_ID=test-project \
  RUN_INFRA=false \
  RUN_ANSIBLE=true \
  RUN_PORTAINER=true \
  RUN_HOST_SYNC=false \
  RUN_HEALTH=false \
  INFISICAL_TOKEN=test-token \
  INFISICAL_AGENT_CLIENT_ID=agent-id \
  INFISICAL_AGENT_CLIENT_SECRET=agent-secret \
  bash "${SCRIPT}")"
if [[ -f "${bootstrap_case_out}" ]]; then
  pass "bootstrap_allows_synced_allowlist_missing: script succeeded without requiring PORTAINER_AUTOMATION_ALLOWED_CIDRS"
else
  fail "bootstrap_allows_synced_allowlist_missing: missing output file"
fi

seed_common_stack_secrets
write_secret_file /stacks/management \
  'HOMARR_SECRET_KEY=homarr-secret' \
  'PORTAINER_ADMIN_PASSWORD=portainer-admin-password'
write_secret_file /stacks/network \
  'VW_ADMIN_TOKEN=vw-admin-secret' \
  'PIHOLE_PASSWORD=pihole-secret'

missing_network_secret_out="$(run_case_expect_fail "missing_network_secret_fails_closed" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  INFISICAL_MACHINE_IDENTITY_ID=test-machine-id \
  INFISICAL_PROJECT_ID=test-project \
  RUN_INFRA=false \
  RUN_ANSIBLE=true \
  RUN_PORTAINER=true \
  RUN_HOST_SYNC=false \
  RUN_HEALTH=false \
  INFISICAL_TOKEN=test-token \
  INFISICAL_AGENT_CLIENT_ID=agent-id \
  INFISICAL_AGENT_CLIENT_SECRET=agent-secret \
  bash "${SCRIPT}")"
assert_contains "missing_network_secret_fails_closed" "Missing required secret(s) in /stacks/network: VW_DB_PASS" "${missing_network_secret_out}"

seed_common_stack_secrets
write_secret_file /management \
  'PORTAINER_API_URL=https://portainer-api.example.com' \
  'PORTAINER_API_KEY=real-looking-api-key'

placeholder_api_url_out="$(run_case_expect_fail "placeholder_portainer_api_url_rejected" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  INFISICAL_MACHINE_IDENTITY_ID=test-machine-id \
  INFISICAL_PROJECT_ID=test-project \
  RUN_INFRA=false \
  RUN_ANSIBLE=false \
  RUN_PORTAINER=true \
  RUN_HOST_SYNC=false \
  RUN_HEALTH=false \
  INFISICAL_TOKEN=test-token \
  bash "${SCRIPT}")"
assert_contains "placeholder_portainer_api_url_rejected" "PORTAINER_API_URL contains a placeholder URL" "${placeholder_api_url_out}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
