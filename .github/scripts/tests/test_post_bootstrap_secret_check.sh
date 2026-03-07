#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/stages/post_bootstrap_secret_check.sh"

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

valid_bcrypt_hash='$2b$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

write_secret_file /management \
  'PORTAINER_API_URL=https://portainer-api.goodoldme.test' \
  'PORTAINER_API_KEY=portainer-api-token'
write_secret_file /stacks/management \
  "PORTAINER_ADMIN_PASSWORD_HASH=${valid_bcrypt_hash}"

run_case "valid_bootstrap_outputs" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  INFISICAL_MACHINE_IDENTITY_ID=test-machine-id \
  INFISICAL_PROJECT_ID=test-project \
  bash "${SCRIPT}" >/dev/null
pass "valid_bootstrap_outputs: script succeeded"

write_secret_file /management \
  'PORTAINER_API_URL=https://portainer-api.goodoldme.test' \
  'PORTAINER_API_KEY=your_portainer_api_key_here'
write_secret_file /stacks/management \
  "PORTAINER_ADMIN_PASSWORD_HASH=${valid_bcrypt_hash}"

placeholder_api_key_out="$(run_case_expect_fail "placeholder_api_key_rejected" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  INFISICAL_MACHINE_IDENTITY_ID=test-machine-id \
  INFISICAL_PROJECT_ID=test-project \
  bash "${SCRIPT}")"
assert_contains "placeholder_api_key_rejected" "PORTAINER_API_KEY contains a placeholder value" "${placeholder_api_key_out}"

write_secret_file /management \
  'PORTAINER_API_URL=https://portainer-api.goodoldme.test' \
  'PORTAINER_API_KEY=portainer-api-token'
write_secret_file /stacks/management \
  'PORTAINER_ADMIN_PASSWORD_HASH=not-a-bcrypt-hash'

invalid_hash_out="$(run_case_expect_fail "invalid_bcrypt_hash_rejected" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  INFISICAL_MACHINE_IDENTITY_ID=test-machine-id \
  INFISICAL_PROJECT_ID=test-project \
  bash "${SCRIPT}")"
assert_contains "invalid_bcrypt_hash_rejected" "PORTAINER_ADMIN_PASSWORD_HASH must be a valid bcrypt hash." "${invalid_hash_out}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
