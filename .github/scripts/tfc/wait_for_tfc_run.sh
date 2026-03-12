#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <RUN_ID> <WORKSPACE_NAME>"
  exit 1
fi

RUN_ID="$1"
WORKSPACE_NAME="$2"

: "${TFC_TOKEN:?TFC_TOKEN is required}"

TFC_API_URL="${TFC_API_URL:-https://app.terraform.io/api/v2}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-7200}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
REQUIRE_MANUAL_CONFIRM="${REQUIRE_MANUAL_CONFIRM:-false}"
FAIL_IF_AUTO_APPLY="${FAIL_IF_AUTO_APPLY:-false}"
SUCCESS_STATUSES="${SUCCESS_STATUSES:-planned_and_finished,applied}"
TERMINAL_FAILURE_STATUSES="${TERMINAL_FAILURE_STATUSES:-errored,canceled,discarded,force_canceled}"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workflow_common.sh"

REQUIRE_MANUAL_CONFIRM="$(to_bool "${REQUIRE_MANUAL_CONFIRM}")"
FAIL_IF_AUTO_APPLY="$(to_bool "${FAIL_IF_AUTO_APPLY}")"

if ! [[ "${WAIT_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( WAIT_TIMEOUT_SECONDS <= 0 )); then
  echo "Invalid WAIT_TIMEOUT_SECONDS='${WAIT_TIMEOUT_SECONDS}'. Expected integer > 0."
  exit 1
fi

if ! [[ "${POLL_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL_SECONDS <= 0 )); then
  echo "Invalid POLL_INTERVAL_SECONDS='${POLL_INTERVAL_SECONDS}'. Expected integer > 0."
  exit 1
fi

if [[ -n "${TFC_ORGANIZATION:-}" ]]; then
  echo "Terraform Cloud run URL: https://app.terraform.io/app/${TFC_ORGANIZATION}/${WORKSPACE_NAME}/runs/${RUN_ID}"
else
  echo "Terraform Cloud run id: ${RUN_ID}"
fi

deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
last_status=""
apply_started="false"
printed_confirm_hint="false"
checked_auto_apply="false"

while (( SECONDS < deadline )); do
  if ! run_json="$(
    curl --silent --show-error --fail \
      --header "Authorization: Bearer ${TFC_TOKEN}" \
      --header "Content-Type: application/vnd.api+json" \
      "${TFC_API_URL%/}/runs/${RUN_ID}"
  )"; then
    echo "Failed to query Terraform Cloud run '${RUN_ID}'."
    exit 1
  fi

  status="$(jq -r '.data.attributes.status // "unknown"' <<<"${run_json}")"
  is_confirmable="$(jq -r '.data.attributes.actions["is-confirmable"] // false' <<<"${run_json}")"
  has_changes="$(jq -r '.data.attributes["has-changes"] // "unknown"' <<<"${run_json}")"
  auto_apply="$(jq -r '.data.attributes["auto-apply"] // false' <<<"${run_json}")"

  if [[ "${status}" != "${last_status}" ]]; then
    echo "Run status: ${status}"
    last_status="${status}"
  fi

  if [[ "${checked_auto_apply}" == "false" && "${FAIL_IF_AUTO_APPLY}" == "true" ]]; then
    checked_auto_apply="true"
    if [[ "${auto_apply}" == "true" ]]; then
      echo "Terraform Cloud run is configured with auto-apply=true."
      echo "Disable auto-apply for '${WORKSPACE_NAME}' to require manual confirmation."
      exit 1
    fi
  fi

  if csv_contains "${status}" "${TERMINAL_FAILURE_STATUSES}"; then
    echo "Run '${RUN_ID}' for workspace '${WORKSPACE_NAME}' failed with terminal status '${status}'."
    exit 1
  fi

  if [[ "${status}" == "apply_queued" || "${status}" == "applying" || "${status}" == "applied" ]]; then
    apply_started="true"
  fi

  if [[ "${REQUIRE_MANUAL_CONFIRM}" == "true" && "${apply_started}" == "false" && "${is_confirmable}" == "true" && "${printed_confirm_hint}" == "false" ]]; then
    echo "Run is confirmable. Confirm and apply in Terraform Cloud to continue."
    printed_confirm_hint="true"
  fi

  if csv_contains "${status}" "${SUCCESS_STATUSES}"; then
    if [[ "${REQUIRE_MANUAL_CONFIRM}" == "true" ]]; then
      if [[ "${status}" == "applied" ]]; then
        echo "Run '${RUN_ID}' for workspace '${WORKSPACE_NAME}' completed successfully with status '${status}'."
        exit 0
      fi

      if [[ "${status}" == "planned_and_finished" && "${is_confirmable}" == "false" && "${has_changes}" == "false" ]]; then
        echo "Run '${RUN_ID}' for workspace '${WORKSPACE_NAME}' completed successfully with no changes."
        exit 0
      fi
    else
      echo "Run '${RUN_ID}' for workspace '${WORKSPACE_NAME}' completed successfully with status '${status}'."
      exit 0
    fi
  fi

  sleep "${POLL_INTERVAL_SECONDS}"
done

echo "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for run '${RUN_ID}' in workspace '${WORKSPACE_NAME}'."
exit 1
