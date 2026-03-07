#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/stacks/verify_trusted_stacks_sha.sh"
STACKS_SHA="0123456789abcdef0123456789abcdef01234567"

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
STATE_ROOT="${TMP_DIR}/state"
mkdir -p "${BIN_DIR}" "${STATE_ROOT}"

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_SCENARIO:?Missing MOCK_SCENARIO}"
: "${MOCK_STATE_DIR:?Missing MOCK_STATE_DIR}"

output_file=""
url=""

while (($# > 0)); do
  case "$1" in
    --output)
      output_file="$2"
      shift 2
      ;;
    --output=*)
      output_file="${1#*=}"
      shift
      ;;
    --write-out|--header)
      shift 2
      ;;
    --write-out=*|--header=*)
      shift
      ;;
    --silent|--show-error|--location)
      shift
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

: "${output_file:?Missing --output destination}"
: "${url:?Missing request URL}"

next_call() {
  local key="$1"
  local counter_file="${MOCK_STATE_DIR}/${key}.count"
  local count=0

  if [[ -f "${counter_file}" ]]; then
    count="$(cat "${counter_file}")"
  fi

  count=$((count + 1))
  printf '%s' "${count}" > "${counter_file}"
  printf '%s' "${count}"
}

body=""

case "${url}" in
  */compare/*)
    case "${MOCK_SCENARIO}" in
      ancestry_fail)
        body='{"status":"behind"}'
        ;;
      *)
        body='{"status":"identical"}'
        ;;
    esac
    ;;
  */check-runs*)
    check_runs_call="$(next_call "check-runs")"
    case "${MOCK_SCENARIO}" in
      checks_only_success)
        body='{"total_count":2,"check_runs":[{"name":"stacks-ci","status":"completed","conclusion":"success"},{"name":"manifest-lint","status":"completed","conclusion":"neutral"}]}'
        ;;
      statuses_only_success|no_signal_immediate_fail|wait_no_signal_to_ready)
        body='{"total_count":0,"check_runs":[]}'
        ;;
      mixed_success|mixed_pending_blocks)
        body='{"total_count":1,"check_runs":[{"name":"stacks-ci","status":"completed","conclusion":"success"}]}'
        ;;
      check_runs_hard_failure)
        body='{"total_count":1,"check_runs":[{"name":"stacks-ci","status":"completed","conclusion":"failure"}]}'
        ;;
      wait_pending_to_timeout)
        body='{"total_count":1,"check_runs":[{"name":"stacks-ci","status":"in_progress","conclusion":null}]}'
        ;;
      *)
        echo "Unhandled MOCK_SCENARIO for check-runs: ${MOCK_SCENARIO}" >&2
        exit 1
        ;;
    esac
    ;;
  */status)
    status_call="$(next_call "status")"
    case "${MOCK_SCENARIO}" in
      checks_only_success|no_signal_immediate_fail)
        body='{"state":"pending","statuses":[]}'
        ;;
      statuses_only_success|mixed_success|check_runs_hard_failure)
        body='{"state":"success","statuses":[{"context":"legacy-ci","state":"success"}]}'
        ;;
      mixed_pending_blocks|wait_pending_to_timeout)
        body='{"state":"pending","statuses":[{"context":"legacy-ci","state":"pending"}]}'
        ;;
      wait_no_signal_to_ready)
        if (( status_call == 1 )); then
          body='{"state":"pending","statuses":[]}'
        else
          body='{"state":"success","statuses":[{"context":"legacy-ci","state":"success"}]}'
        fi
        ;;
      *)
        echo "Unhandled MOCK_SCENARIO for status: ${MOCK_SCENARIO}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unhandled request URL: ${url}" >&2
    exit 1
    ;;
esac

printf '%s' "${body}" > "${output_file}"
printf '200'
EOF
chmod +x "${BIN_DIR}/curl"

cat > "${BIN_DIR}/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${FAKE_SLEEP_MODE:-noop}" in
  noop)
    exit 0
    ;;
  real)
    exec /bin/sleep "$@"
    ;;
  *)
    echo "Unsupported FAKE_SLEEP_MODE='${FAKE_SLEEP_MODE:-}'" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BIN_DIR}/sleep"

run_verify() {
  local scenario="$1"
  shift
  local state_dir="${STATE_ROOT}/${scenario}"

  mkdir -p "${state_dir}"

  env \
    PATH="${BIN_DIR}:${PATH}" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_STATE_DIR="${state_dir}" \
    STACKS_REPO_READ_TOKEN=test-token \
    "$@" \
    bash "${SCRIPT}" "${STACKS_SHA}"
}

ancestry_fail_out="$(run_case_expect_fail "ancestry_fail" run_verify ancestry_fail)"
assert_contains "ancestry_fail" "Main ancestry result: fail (compare status: behind)" "${ancestry_fail_out}"
assert_contains "ancestry_fail" "Stacks SHA '${STACKS_SHA}' is NOT trusted." "${ancestry_fail_out}"

checks_only_success_out="$(run_case "checks_only_success" run_verify checks_only_success)"
assert_contains "checks_only_success" "Check-runs signal: present=true, total=2, violating=0, ready=true" "${checks_only_success_out}"
assert_contains "checks_only_success" "Legacy commit status signal: present=false, contexts=0, state=pending, ready=false" "${checks_only_success_out}"
assert_contains "checks_only_success" "Stacks SHA '${STACKS_SHA}' is trusted." "${checks_only_success_out}"

statuses_only_success_out="$(run_case "statuses_only_success" run_verify statuses_only_success)"
assert_contains "statuses_only_success" "Check-runs signal: present=false, total=0, violating=0, ready=false" "${statuses_only_success_out}"
assert_contains "statuses_only_success" "Legacy commit status signal: present=true, contexts=1, state=success, ready=true" "${statuses_only_success_out}"
assert_contains "statuses_only_success" "Stacks SHA '${STACKS_SHA}' is trusted." "${statuses_only_success_out}"

mixed_success_out="$(run_case "mixed_success" run_verify mixed_success)"
assert_contains "mixed_success" "Check-runs signal: present=true, total=1, violating=0, ready=true" "${mixed_success_out}"
assert_contains "mixed_success" "Legacy commit status signal: present=true, contexts=1, state=success, ready=true" "${mixed_success_out}"
assert_contains "mixed_success" "Stacks SHA '${STACKS_SHA}' is trusted." "${mixed_success_out}"

mixed_pending_blocks_out="$(run_case_expect_fail "mixed_pending_blocks" run_verify mixed_pending_blocks)"
assert_contains "mixed_pending_blocks" "Legacy commit status signal: present=true, contexts=1, state=pending, ready=false" "${mixed_pending_blocks_out}"
assert_contains "mixed_pending_blocks" "Stacks SHA '${STACKS_SHA}' is NOT trusted." "${mixed_pending_blocks_out}"

check_runs_hard_failure_out="$(run_case_expect_fail "check_runs_hard_failure" run_verify check_runs_hard_failure)"
assert_contains "check_runs_hard_failure" "Failing or incomplete check-runs:" "${check_runs_hard_failure_out}"
assert_contains "check_runs_hard_failure" "- stacks-ci [status=completed, conclusion=failure]" "${check_runs_hard_failure_out}"
assert_contains "check_runs_hard_failure" "Stacks SHA '${STACKS_SHA}' is NOT trusted." "${check_runs_hard_failure_out}"

no_signal_immediate_fail_out="$(run_case_expect_fail "no_signal_immediate_fail" run_verify no_signal_immediate_fail)"
assert_contains "no_signal_immediate_fail" "No CI trust signals found yet. At least one green GitHub Checks or legacy commit status signal is required." "${no_signal_immediate_fail_out}"
assert_contains "no_signal_immediate_fail" "Stacks SHA '${STACKS_SHA}' is NOT trusted." "${no_signal_immediate_fail_out}"

wait_no_signal_to_ready_out="$(run_case "wait_no_signal_to_ready" run_verify wait_no_signal_to_ready WAIT_FOR_SUCCESS=true WAIT_TIMEOUT_SECONDS=3 POLL_INTERVAL_SECONDS=1)"
assert_contains "wait_no_signal_to_ready" "Polling stacks trust checks for ${STACKS_SHA}..." "${wait_no_signal_to_ready_out}"
assert_contains "wait_no_signal_to_ready" "No CI trust signals found yet. At least one green GitHub Checks or legacy commit status signal is required." "${wait_no_signal_to_ready_out}"
assert_contains "wait_no_signal_to_ready" "Legacy commit status signal: present=true, contexts=1, state=success, ready=true" "${wait_no_signal_to_ready_out}"
assert_contains "wait_no_signal_to_ready" "Stacks SHA '${STACKS_SHA}' is trusted." "${wait_no_signal_to_ready_out}"

wait_pending_to_timeout_out="$(run_case_expect_fail "wait_pending_to_timeout" run_verify wait_pending_to_timeout WAIT_FOR_SUCCESS=true WAIT_TIMEOUT_SECONDS=1 POLL_INTERVAL_SECONDS=1 FAKE_SLEEP_MODE=real)"
assert_contains "wait_pending_to_timeout" "Check-runs signal: present=true, total=1, violating=1, ready=false" "${wait_pending_to_timeout_out}"
assert_contains "wait_pending_to_timeout" "Legacy commit status signal: present=true, contexts=1, state=pending, ready=false" "${wait_pending_to_timeout_out}"
assert_contains "wait_pending_to_timeout" "Timed out after 1s waiting for stacks SHA '${STACKS_SHA}' checks to succeed." "${wait_pending_to_timeout_out}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
