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
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-1800}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"

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

  if [[ "${status}" != "${last_status}" ]]; then
    echo "Run status: ${status}"
    last_status="${status}"
  fi

  case "${status}" in
    planned_and_finished|applied)
      echo "Run '${RUN_ID}' for workspace '${WORKSPACE_NAME}' completed successfully with status '${status}'."
      exit 0
      ;;
    errored|canceled|discarded|force_canceled)
      echo "Run '${RUN_ID}' for workspace '${WORKSPACE_NAME}' failed with terminal status '${status}'."
      exit 1
      ;;
  esac

  sleep "${POLL_INTERVAL_SECONDS}"
done

echo "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for run '${RUN_ID}' in workspace '${WORKSPACE_NAME}'."
exit 1
