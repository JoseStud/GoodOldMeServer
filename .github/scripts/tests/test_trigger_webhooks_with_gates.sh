#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/stacks/trigger_webhooks_with_gates.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not found; install yq to run trigger_webhooks_with_gates tests."
  exit 0
fi

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

assert_eq() {
  local case_name="$1"
  local key="$2"
  local expected="$3"
  local actual="$4"

  if [[ "${expected}" == "${actual}" ]]; then
    pass "${case_name}: ${key}=${expected}"
  else
    fail "${case_name}: ${key} expected='${expected}' actual='${actual}'"
  fi
}

assert_contains() {
  local case_name="$1"
  local pattern="$2"
  local file="$3"

  if grep -Fq "${pattern}" "${file}"; then
    pass "${case_name}: found '${pattern}'"
  else
    fail "${case_name}: missing '${pattern}'"
  fi
}

assert_not_contains() {
  local case_name="$1"
  local pattern="$2"
  local file="$3"

  if grep -Fq "${pattern}" "${file}"; then
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

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [[ "${arg}" == "-X" || "${arg}" == "--request" ]]; then
    next_index=$((i + 1))
    method="${!next_index}"
  fi
done

url="${!#}"
if [[ -n "${CURL_LOG_FILE:-}" ]]; then
  echo "${method} ${url}" >> "${CURL_LOG_FILE}"
fi

printf '200'
EOF
chmod +x "${BIN_DIR}/curl"

export PATH="${BIN_DIR}:${PATH}"

full_log="${TMP_DIR}/full_reconcile.log"
touch "${full_log}"
full_out="$(run_case "full_reconcile" env \
  PATH="${PATH}" \
  CURL_LOG_FILE="${full_log}" \
  FULL_STACKS_RECONCILE=true \
  BASE_DOMAIN=example.com \
  WEBHOOK_URL_GATEWAY=https://hooks/gateway \
  WEBHOOK_URL_AUTH=https://hooks/auth \
  WEBHOOK_URL_NETWORK=https://hooks/network \
  WEBHOOK_URL_OBSERVABILITY=https://hooks/observability \
  WEBHOOK_URL_AI_INTERFACE=https://hooks/ai-interface \
  WEBHOOK_URL_UPTIME=https://hooks/uptime \
  WEBHOOK_URL_CLOUD=https://hooks/cloud \
  bash "${SCRIPT}" "${ROOT_DIR}/stacks/stacks.yaml")"

assert_contains "full_reconcile" "FULL_STACKS_RECONCILE=true: redeploying all Portainer-managed stacks." "${full_out}"

post_order="$(
  awk '$1 == "POST" { sub("^https://hooks/", "", $2); print $2 }' "${full_log}" | paste -sd, -
)"
assert_eq "full_reconcile" "post_order" "gateway,auth,network,observability,ai-interface,uptime,cloud" "${post_order}"
assert_not_contains "full_reconcile" "management" "${full_log}"

missing_manifest="${TMP_DIR}/missing-webhook.yaml"
cat > "${missing_manifest}" <<'EOF'
version: 1
stacks:
  alpha:
    compose_path: alpha/docker-compose.yml
    portainer_managed: true
    depends_on: []
EOF

missing_out="$(run_case_expect_fail "missing_webhook" env \
  PATH="${PATH}" \
  FULL_STACKS_RECONCILE=true \
  bash "${SCRIPT}" "${missing_manifest}")"
assert_contains "missing_webhook" "Missing WEBHOOK_URL_ALPHA for stack 'alpha'." "${missing_out}"

cycle_manifest="${TMP_DIR}/cycle.yaml"
cat > "${cycle_manifest}" <<'EOF'
version: 1
stacks:
  alpha:
    compose_path: alpha/docker-compose.yml
    portainer_managed: true
    depends_on: [beta]
  beta:
    compose_path: beta/docker-compose.yml
    portainer_managed: true
    depends_on: [alpha]
EOF

cycle_out="$(run_case_expect_fail "cycle_detected" env \
  PATH="${PATH}" \
  FULL_STACKS_RECONCILE=true \
  WEBHOOK_URL_ALPHA=https://hooks/alpha \
  WEBHOOK_URL_BETA=https://hooks/beta \
  bash "${SCRIPT}" "${cycle_manifest}")"
assert_contains "cycle_detected" "Dependency cycle detected at stack 'alpha'." "${cycle_out}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
