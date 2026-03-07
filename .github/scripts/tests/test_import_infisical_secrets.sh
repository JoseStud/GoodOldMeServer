#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/import_infisical_secrets.sh"

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

assert_not_contains() {
  local case_name="$1"
  local pattern="$2"
  local file="$3"

  if grep -Fq -- "${pattern}" "${file}"; then
    fail "${case_name}: unexpected '${pattern}'"
  else
    pass "${case_name}: absent '${pattern}'"
  fi
}

BIN_DIR="${TMP_DIR}/bin"
LOG_FILE="${TMP_DIR}/infisical.log"
mkdir -p "${BIN_DIR}"

cat > "${BIN_DIR}/infisical" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 || "$1" != "secrets" || "$2" != "set" ]]; then
  echo "Unexpected infisical invocation: $*" >&2
  exit 1
fi

printf '%s\n' "$*" >> "${FAKE_INFISICAL_LOG}"
EOF
chmod +x "${BIN_DIR}/infisical"

env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_LOG="${LOG_FILE}" \
  bash "${SCRIPT}" >/dev/null

assert_contains "import_seeds_operator_managed_values" "secrets set PORTAINER_ADMIN_PASSWORD=your_portainer_admin_password --env=prod --path=/stacks/management" "${LOG_FILE}"
assert_contains "import_seeds_operator_managed_values" "secrets set ACME_EMAIL=admin@example.com --env=prod --path=/stacks/gateway" "${LOG_FILE}"
assert_contains "import_seeds_operator_managed_values" "secrets set AUTHELIA_NOTIFIER_SMTP_USERNAME=your_smtp_username --env=prod --path=/stacks/identity" "${LOG_FILE}"
assert_contains "import_seeds_operator_managed_values" "secrets set ALERTMANAGER_WEBHOOK_URL=https://hooks.example.com/services/replace-me --env=prod --path=/stacks/observability" "${LOG_FILE}"
assert_not_contains "import_skips_portainer_management_outputs" "PORTAINER_URL=" "${LOG_FILE}"
assert_not_contains "import_skips_portainer_management_outputs" "PORTAINER_API_URL=" "${LOG_FILE}"
assert_not_contains "import_skips_portainer_management_outputs" "PORTAINER_API_KEY=" "${LOG_FILE}"
assert_not_contains "import_skips_webhook_outputs" "PORTAINER_WEBHOOK_URLS=" "${LOG_FILE}"
assert_not_contains "import_skips_webhook_outputs" "WEBHOOK_URL_GATEWAY=" "${LOG_FILE}"
assert_not_contains "import_skips_management_derived_outputs" "PORTAINER_ADMIN_PASSWORD_HASH=" "${LOG_FILE}"
assert_not_contains "import_skips_management_derived_outputs" "PORTAINER_AUTOMATION_ALLOWED_CIDRS=" "${LOG_FILE}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
