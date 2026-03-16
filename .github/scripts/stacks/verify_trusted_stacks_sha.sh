#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <STACKS_SHA>"
  exit 1
fi

STACKS_SHA="$1"
STACKS_REPO_OWNER="${STACKS_REPO_OWNER:-JoseStud}"
STACKS_REPO_NAME="${STACKS_REPO_NAME:-stacks}"
STACKS_MAIN_BRANCH="${STACKS_MAIN_BRANCH:-main}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
WAIT_FOR_SUCCESS="${WAIT_FOR_SUCCESS:-false}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-15}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workflow_common.sh"

WAIT_FOR_SUCCESS="$(to_bool "${WAIT_FOR_SUCCESS}")"

if ! [[ "${WAIT_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( WAIT_TIMEOUT_SECONDS <= 0 )); then
  echo "Invalid WAIT_TIMEOUT_SECONDS='${WAIT_TIMEOUT_SECONDS}'. Expected integer > 0."
  exit 1
fi

if ! [[ "${POLL_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL_SECONDS <= 0 )); then
  echo "Invalid POLL_INTERVAL_SECONDS='${POLL_INTERVAL_SECONDS}'. Expected integer > 0."
  exit 1
fi

AUTH_TOKEN="${STACKS_REPO_READ_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "${AUTH_TOKEN}" ]]; then
  echo "Missing GitHub API token. Set STACKS_REPO_READ_TOKEN or GITHUB_TOKEN."
  exit 1
fi

if ! is_valid_sha "${STACKS_SHA}"; then
  echo "Invalid STACKS_SHA '${STACKS_SHA}'. Expected a 40-character lowercase hexadecimal commit SHA."
  exit 1
fi

API_BODY=""
api_get_json() {
  local url="$1"
  local context="$2"
  local tmp_file http_code

  tmp_file="$(mktemp)"
  http_code="$(
    curl --silent --show-error --location \
      --output "${tmp_file}" \
      --write-out "%{http_code}" \
      --header "Authorization: Bearer ${AUTH_TOKEN}" \
      --header "Accept: application/vnd.github+json" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      "${url}"
  )"
  API_BODY="$(cat "${tmp_file}")"
  rm -f "${tmp_file}"

  case "${http_code}" in
    200)
      return 0
      ;;
    403)
      echo "GitHub API 403 while fetching ${context}. Token may not have access to ${STACKS_REPO_OWNER}/${STACKS_REPO_NAME}."
      return 1
      ;;
    404)
      echo "GitHub API 404 while fetching ${context}. Repository or SHA '${STACKS_SHA}' was not found."
      return 1
      ;;
    *)
      echo "GitHub API ${http_code} while fetching ${context}."
      if [[ -n "${API_BODY}" ]]; then
        echo "Response: ${API_BODY}"
      fi
      return 1
      ;;
  esac
}

compare_url="${GITHUB_API_URL%/}/repos/${STACKS_REPO_OWNER}/${STACKS_REPO_NAME}/compare/${STACKS_SHA}...${STACKS_MAIN_BRANCH}"
if ! api_get_json "${compare_url}" "compare (${STACKS_SHA}...${STACKS_MAIN_BRANCH})"; then
  exit 1
fi

ancestry_status="$(jq -r '.status // "unknown"' <<<"${API_BODY}")"
if [[ "${ancestry_status}" != "ahead" && "${ancestry_status}" != "identical" ]]; then
  echo "Main ancestry result: fail (compare status: ${ancestry_status})"
  echo "Stacks SHA '${STACKS_SHA}' is NOT trusted."
  exit 1
fi

echo "Main ancestry result: pass (compare status: ${ancestry_status})"

fetch_check_and_status() {
  local check_runs_base_url check_runs_all check_runs_total page page_url page_total page_runs
  local page_count current_count check_runs_bad check_runs_bad_count check_runs_hard_fail_count
  local combined_status_url combined_state combined_status_context_count
  local check_runs_signal_present check_runs_ready check_runs_hard_failure
  local statuses_signal_present statuses_ready statuses_hard_failure
  local signal_channels_present ready hard_failure

  check_runs_base_url="${GITHUB_API_URL%/}/repos/${STACKS_REPO_OWNER}/${STACKS_REPO_NAME}/commits/${STACKS_SHA}/check-runs"
  check_runs_all='[]'
  check_runs_total=0
  page=1

  while true; do
    page_url="${check_runs_base_url}?per_page=100&page=${page}"
    if ! api_get_json "${page_url}" "check-runs page ${page}"; then
      return 1
    fi

    page_total="$(jq -r '.total_count // 0' <<<"${API_BODY}")"
    if [[ "${page}" == "1" ]]; then
      check_runs_total="${page_total}"
    fi

    page_runs="$(jq -c '.check_runs // []' <<<"${API_BODY}")"
    check_runs_all="$(jq -cn --argjson existing "${check_runs_all}" --argjson page_runs "${page_runs}" '$existing + $page_runs')"

    page_count="$(jq -r '.check_runs | length' <<<"${API_BODY}")"
    current_count="$(jq -r 'length' <<<"${check_runs_all}")"

    if (( page_count == 0 )) || (( current_count >= check_runs_total )); then
      break
    fi
    page=$((page + 1))
  done

  # Deduplicate by name, keeping the first (newest) run per check name.
  # The GitHub API returns check-runs newest-first; unique_by preserves the
  # first occurrence, so this selects the most recent result per check name.
  # This prevents a re-run's older failed attempt from blocking trust.
  check_runs_deduped="$(jq -c 'unique_by(.name)' <<<"${check_runs_all}")"

  check_runs_bad="$(jq -c '[
    .[]
    | select((.status != "completed") or (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped"))
    | {
        name: (.name // "<unnamed>"),
        status: (.status // "unknown"),
        conclusion: (.conclusion // "none")
      }
  ]' <<<"${check_runs_deduped}")"
  check_runs_bad_count="$(jq -r 'length' <<<"${check_runs_bad}")"

  check_runs_hard_fail_count="$(jq -r '[
    .[]
    | select(.status == "completed" and (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped"))
  ] | length' <<<"${check_runs_deduped}")"

  combined_status_url="${GITHUB_API_URL%/}/repos/${STACKS_REPO_OWNER}/${STACKS_REPO_NAME}/commits/${STACKS_SHA}/status"
  if ! api_get_json "${combined_status_url}" "combined commit status"; then
    return 1
  fi

  combined_state="$(jq -r '.state // "unknown"' <<<"${API_BODY}")"
  combined_status_context_count="$(jq -r '(.statuses // []) | length' <<<"${API_BODY}")"

  check_runs_signal_present="false"
  if (( check_runs_total > 0 )); then
    check_runs_signal_present="true"
  fi

  check_runs_ready="false"
  if [[ "${check_runs_signal_present}" == "true" ]] && (( check_runs_bad_count == 0 )); then
    check_runs_ready="true"
  fi

  check_runs_hard_failure="false"
  if (( check_runs_hard_fail_count > 0 )); then
    check_runs_hard_failure="true"
  fi

  statuses_signal_present="false"
  if (( combined_status_context_count > 0 )); then
    statuses_signal_present="true"
  fi

  statuses_ready="false"
  statuses_hard_failure="false"
  if [[ "${statuses_signal_present}" == "true" ]]; then
    case "${combined_state}" in
      success)
        statuses_ready="true"
        ;;
      failure|error)
        statuses_hard_failure="true"
        ;;
    esac
  fi

  signal_channels_present=0
  if [[ "${check_runs_signal_present}" == "true" ]]; then
    signal_channels_present=$((signal_channels_present + 1))
  fi
  if [[ "${statuses_signal_present}" == "true" ]]; then
    signal_channels_present=$((signal_channels_present + 1))
  fi

  echo "Check-runs signal: present=${check_runs_signal_present}, total=${check_runs_total}, violating=${check_runs_bad_count}, ready=${check_runs_ready}"
  if (( check_runs_bad_count > 0 )); then
    echo "Failing or incomplete check-runs:"
    jq -r '.[] | "- \(.name) [status=\(.status), conclusion=\(.conclusion)]"' <<<"${check_runs_bad}"
  fi
  echo "Legacy commit status signal: present=${statuses_signal_present}, contexts=${combined_status_context_count}, state=${combined_state}, ready=${statuses_ready}"
  if (( signal_channels_present == 0 )); then
    echo "No CI trust signals found yet. At least one green GitHub Checks or legacy commit status signal is required."
  fi

  hard_failure="false"
  if [[ "${check_runs_hard_failure}" == "true" || "${statuses_hard_failure}" == "true" ]]; then
    hard_failure="true"
  fi

  ready="false"
  if (( signal_channels_present > 0 )) && [[ "${hard_failure}" == "false" ]]; then
    ready="true"
    if [[ "${check_runs_signal_present}" == "true" && "${check_runs_ready}" != "true" ]]; then
      ready="false"
    fi
    if [[ "${statuses_signal_present}" == "true" && "${statuses_ready}" != "true" ]]; then
      ready="false"
    fi
  fi

  echo "::result::ready=${ready}"
  echo "::result::hard_failure=${hard_failure}"
}

result_field() {
  local field_name="$1"
  local result_blob="$2"

  grep "^::result::${field_name}=" <<<"${result_blob}" | tail -n1 | sed "s/^::result::${field_name}=//"
}

print_result_logs() {
  local result_blob="$1"

  grep -v '^::result::' <<<"${result_blob}"
}

if [[ "${WAIT_FOR_SUCCESS}" != "true" ]]; then
  result="$(fetch_check_and_status)" || exit 1
  print_result_logs "${result}"
  ready="$(result_field "ready" "${result}")"
  hard_failure="$(result_field "hard_failure" "${result}")"

  if [[ "${ready}" == "true" && "${hard_failure}" == "false" ]]; then
    echo "Stacks SHA '${STACKS_SHA}' is trusted."
    exit 0
  fi

  echo "Stacks SHA '${STACKS_SHA}' is NOT trusted."
  exit 1
fi

deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  echo "Polling stacks trust checks for ${STACKS_SHA}..."
  result="$(fetch_check_and_status)" || exit 1
  print_result_logs "${result}"

  ready="$(result_field "ready" "${result}")"
  hard_failure="$(result_field "hard_failure" "${result}")"

  if [[ "${ready}" == "true" ]]; then
    echo "Stacks SHA '${STACKS_SHA}' is trusted."
    exit 0
  fi

  if [[ "${hard_failure}" == "true" ]]; then
    echo "Stacks SHA '${STACKS_SHA}' is NOT trusted due to terminal check failure."
    exit 1
  fi

  sleep "${POLL_INTERVAL_SECONDS}"
done

echo "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for stacks SHA '${STACKS_SHA}' checks to succeed."
exit 1
