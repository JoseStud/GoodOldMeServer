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

success_log="${TMP_DIR}/success-infisical.log"
touch "${success_log}"

run_case "import_with_explicit_project" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_LOG="${success_log}" \
  INFISICAL_PROJECT_ID=test-project \
  bash "${SCRIPT}" >/dev/null

assert_contains "import_seeds_operator_managed_values" "secrets set PORTAINER_ADMIN_PASSWORD=your_portainer_admin_password --env=prod --projectId=test-project --path=/stacks/management" "${success_log}"
assert_contains "import_seeds_operator_managed_values" "secrets set ACME_EMAIL=admin@example.com --env=prod --projectId=test-project --path=/stacks/gateway" "${success_log}"
assert_contains "import_seeds_operator_managed_values" "secrets set AUTHELIA_NOTIFIER_SMTP_USERNAME=your_smtp_username --env=prod --projectId=test-project --path=/stacks/identity" "${success_log}"
assert_contains "import_seeds_operator_managed_values" "secrets set ALERTMANAGER_WEBHOOK_URL=https://hooks.example.com/services/replace-me --env=prod --projectId=test-project --path=/stacks/observability" "${success_log}"
assert_not_contains "import_skips_portainer_management_outputs" "PORTAINER_URL=" "${success_log}"
assert_not_contains "import_skips_portainer_management_outputs" "PORTAINER_API_URL=" "${success_log}"
assert_not_contains "import_skips_portainer_management_outputs" "PORTAINER_API_KEY=" "${success_log}"
assert_not_contains "import_skips_webhook_outputs" "PORTAINER_WEBHOOK_URLS=" "${success_log}"
assert_not_contains "import_skips_webhook_outputs" "WEBHOOK_URL_GATEWAY=" "${success_log}"
assert_not_contains "import_skips_management_derived_outputs" "PORTAINER_ADMIN_PASSWORD_HASH=" "${success_log}"
assert_not_contains "import_skips_management_derived_outputs" "PORTAINER_AUTOMATION_ALLOWED_CIDRS=" "${success_log}"

missing_project_log="${TMP_DIR}/missing-project-infisical.log"
touch "${missing_project_log}"
missing_project_out="$(run_case_expect_fail "import_requires_project_id" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_LOG="${missing_project_log}" \
  bash "${SCRIPT}")"
assert_contains "import_requires_project_id" "INFISICAL_PROJECT_ID is required" "${missing_project_out}"
assert_not_contains "import_requires_project_id" "secrets set" "${missing_project_log}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
