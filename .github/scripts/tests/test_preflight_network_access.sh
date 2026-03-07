#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/network/preflight_network_access.sh"

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

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

argv="$*"
family_flag=""
url=""

if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
  echo "${argv}" >> "${FAKE_CURL_LOG}"
fi

while (($# > 0)); do
  case "$1" in
    --ipv4)
      family_flag="ipv4"
      shift
      ;;
    --ipv6)
      family_flag="ipv6"
      shift
      ;;
    --4|--6)
      echo "Unexpected curl option: $1" >&2
      exit 1
      ;;
    -fsS|-sS)
      shift
      ;;
    --retry|--retry-delay|--max-time|-o|-w)
      if (($# < 2)); then
        echo "Missing curl argument for $1" >&2
        exit 1
      fi
      shift 2
      ;;
    --)
      shift
      if (($# != 1)); then
        echo "Unexpected curl argv after --: $*" >&2
        exit 1
      fi
      url="$1"
      shift
      ;;
    -*)
      echo "Unexpected curl option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "${url}" ]]; then
        echo "Unexpected extra curl argument: $1" >&2
        exit 1
      fi
      url="$1"
      shift
      ;;
  esac
done

if [[ -z "${url}" ]]; then
  echo "Missing curl URL" >&2
  exit 1
fi

case "${url}" in
  https://api.ipify.org)
    if [[ "${family_flag}" != "ipv4" ]]; then
      echo "Expected --ipv4 for ${url}" >&2
      exit 1
    fi
    printf '%s' "${FAKE_RUNNER_IPV4:-203.0.113.10}"
    ;;
  https://api64.ipify.org)
    if [[ "${family_flag}" != "ipv6" ]]; then
      echo "Expected --ipv6 for ${url}" >&2
      exit 1
    fi
    printf '%s' "${FAKE_RUNNER_IPV6:-2001:db8::10}"
    ;;
  */api/system/status)
    if [[ -n "${family_flag}" ]]; then
      echo "Unexpected IP family flag for ${url}" >&2
      exit 1
    fi
    printf '%s' "${FAKE_PORTAINER_STATUS:-401}"
    ;;
  *)
    echo "Unexpected curl URL: ${url}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BIN_DIR}/curl"

cat > "${BIN_DIR}/nc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_NC_LOG:-}" ]]; then
  echo "$*" >> "${FAKE_NC_LOG}"
fi
exit 0
EOF
chmod +x "${BIN_DIR}/nc"

ipv4_inventory="${TMP_DIR}/inventory-ipv4.yml"
cat > "${ipv4_inventory}" <<'EOF'
all:
  hosts:
    oci-worker:
      ansible_host: 203.0.113.50
EOF

portainer_policy='{"oci_ssh":{"enabled":false,"source_ranges":[]},"gcp_ssh":{"enabled":false,"source_ranges":[]},"portainer_api":{"source_ranges":["203.0.113.10/32","2001:db8::10/128"]}}'
ssh_policy='{"oci_ssh":{"enabled":true,"source_ranges":["203.0.113.10/32"]},"gcp_ssh":{"enabled":false,"source_ranges":[]},"portainer_api":{"source_ranges":["198.51.100.0/24"]}}'
ssh_disabled_policy='{"oci_ssh":{"enabled":false,"source_ranges":[]},"gcp_ssh":{"enabled":false,"source_ranges":[]},"portainer_api":{"source_ranges":["203.0.113.10/32","2001:db8::10/128"]}}'
portainer_missing_policy='{"oci_ssh":{"enabled":false,"source_ranges":[]},"gcp_ssh":{"enabled":false,"source_ranges":[]},"portainer_api":{"source_ranges":["198.51.100.0/24","2001:db8::/128"]}}'

curl_log_1="${TMP_DIR}/curl-portainer.log"
nc_log_1="${TMP_DIR}/nc-portainer.log"
touch "${curl_log_1}" "${nc_log_1}"
case1_out="$(run_case "portainer_only_ssh_disabled" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_CURL_LOG="${curl_log_1}" \
  FAKE_NC_LOG="${nc_log_1}" \
  NETWORK_ACCESS_POLICY_JSON="${portainer_policy}" \
  RUN_ANSIBLE=false \
  RUN_HOST_SYNC=false \
  RUN_CONFIG=false \
  RUN_HEALTH=false \
  RUN_PORTAINER=true \
  PORTAINER_API_URL=https://portainer.example.com \
  bash "${SCRIPT}")"
assert_contains "portainer_only_ssh_disabled" "Runner egress policy check passed: IPv4=203.0.113.10, IPv6=2001:db8::10" "${case1_out}"
assert_contains "portainer_only_ssh_disabled" "Portainer API preflight passed (HTTP 401)." "${case1_out}"
assert_contains "portainer_only_ssh_disabled" "--ipv4 -fsS --retry 3 --retry-delay 1 --max-time 10 https://api.ipify.org" "${curl_log_1}"
assert_contains "portainer_only_ssh_disabled" "--ipv6 -fsS --retry 3 --retry-delay 1 --max-time 10 https://api64.ipify.org" "${curl_log_1}"
assert_contains "portainer_only_ssh_disabled" "-sS -o /dev/null -w %{http_code} --max-time 10 https://portainer.example.com/api/system/status" "${curl_log_1}"
assert_not_contains "portainer_only_ssh_disabled" "22" "${nc_log_1}"

curl_log_2="${TMP_DIR}/curl-ssh.log"
nc_log_2="${TMP_DIR}/nc-ssh.log"
touch "${curl_log_2}" "${nc_log_2}"
case2_out="$(run_case "ssh_only_ignores_portainer" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_CURL_LOG="${curl_log_2}" \
  FAKE_NC_LOG="${nc_log_2}" \
  NETWORK_ACCESS_POLICY_JSON="${ssh_policy}" \
  RUN_ANSIBLE=false \
  RUN_HOST_SYNC=true \
  RUN_CONFIG=false \
  RUN_HEALTH=false \
  RUN_PORTAINER=false \
  INVENTORY_FILE="${ipv4_inventory}" \
  bash "${SCRIPT}")"
assert_contains "ssh_only_ignores_portainer" "Runner egress policy check passed: IPv4=203.0.113.10, IPv6=n/a" "${case2_out}"
assert_contains "ssh_only_ignores_portainer" "SSH reachability preflight passed for all inventory hosts." "${case2_out}"
assert_contains "ssh_only_ignores_portainer" "--ipv4 -fsS --retry 3 --retry-delay 1 --max-time 10 https://api.ipify.org" "${curl_log_2}"
assert_contains "ssh_only_ignores_portainer" "-4 -z -w5 203.0.113.50 22" "${nc_log_2}"
assert_not_contains "ssh_only_ignores_portainer" "https://api64.ipify.org" "${curl_log_2}"
assert_not_contains "ssh_only_ignores_portainer" "/api/system/status" "${curl_log_2}"

case3_out="$(run_case_expect_fail "required_ssh_family_disabled" env \
  PATH="${BIN_DIR}:${PATH}" \
  NETWORK_ACCESS_POLICY_JSON="${ssh_disabled_policy}" \
  RUN_ANSIBLE=false \
  RUN_HOST_SYNC=false \
  RUN_CONFIG=true \
  RUN_HEALTH=false \
  RUN_PORTAINER=false \
  INVENTORY_FILE="${ipv4_inventory}" \
  bash "${SCRIPT}")"
assert_contains "required_ssh_family_disabled" "network_access_policy.oci_ssh.enabled is false but the current run requires IPv4 SSH access." "${case3_out}"

case4_out="$(run_case_expect_fail "required_portainer_coverage_missing" env \
  PATH="${BIN_DIR}:${PATH}" \
  NETWORK_ACCESS_POLICY_JSON="${portainer_missing_policy}" \
  RUN_ANSIBLE=false \
  RUN_HOST_SYNC=false \
  RUN_CONFIG=false \
  RUN_HEALTH=true \
  RUN_PORTAINER=false \
  PORTAINER_API_URL=https://portainer.example.com \
  bash "${SCRIPT}")"
assert_contains "required_portainer_coverage_missing" "Runner IPv4 egress is not in network_access_policy.portainer_api.source_ranges." "${case4_out}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
