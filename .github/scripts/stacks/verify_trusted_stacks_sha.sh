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

if ! [[ "${STACKS_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
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

  check_runs_bad="$(jq -c '[
    .[]
    | select((.status != "completed") or (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped"))
    | {
        name: (.name // "<unnamed>"),
        status: (.status // "unknown"),
        conclusion: (.conclusion // "none")
      }
  ]' <<<"${check_runs_all}")"
  check_runs_bad_count="$(jq -r 'length' <<<"${check_runs_bad}")"

  check_runs_hard_fail_count="$(jq -r '[
    .[]
    | select(.status == "completed" and (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped"))
  ] | length' <<<"${check_runs_all}")"

  combined_status_url="${GITHUB_API_URL%/}/repos/${STACKS_REPO_OWNER}/${STACKS_REPO_NAME}/commits/${STACKS_SHA}/status"
  if ! api_get_json "${combined_status_url}" "combined commit status"; then
    return 1
  fi

  combined_state="$(jq -r '.state // "unknown"' <<<"${API_BODY}")"

  echo "Check-runs totals: total=${check_runs_total}, violating=${check_runs_bad_count}"
  if (( check_runs_bad_count > 0 )); then
    echo "Failing or incomplete check-runs:"
    jq -r '.[] | "- \(.name) [status=\(.status), conclusion=\(.conclusion)]"' <<<"${check_runs_bad}"
  fi
  echo "Combined status state: ${combined_state}"

  hard_failure="false"
  if (( check_runs_hard_fail_count > 0 )); then
    hard_failure="true"
  fi
  if [[ "${combined_state}" == "failure" || "${combined_state}" == "error" ]]; then
    hard_failure="true"
  fi

  ready="false"
  if (( check_runs_total > 0 )) && (( check_runs_bad_count == 0 )) && [[ "${combined_state}" == "success" ]]; then
    ready="true"
  fi

  echo "ready=${ready}"
  echo "hard_failure=${hard_failure}"
}

if [[ "${WAIT_FOR_SUCCESS}" != "true" ]]; then
  result="$(fetch_check_and_status)" || exit 1
  ready="$(awk -F= '$1=="ready" {print $2}' <<<"${result}" | tail -n1)"
  hard_failure="$(awk -F= '$1=="hard_failure" {print $2}' <<<"${result}" | tail -n1)"

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

  ready="$(awk -F= '$1=="ready" {print $2}' <<<"${result}" | tail -n1)"
  hard_failure="$(awk -F= '$1=="hard_failure" {print $2}' <<<"${result}" | tail -n1)"

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
