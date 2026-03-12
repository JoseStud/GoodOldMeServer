#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${RUN_ID:?RUN_ID is required}"
: "${TFC_WORKSPACE:?TFC_WORKSPACE is required}"

exit_if_shadow_mode "SHADOW_MODE=true: skipping Terraform Cloud wait loop for run ${RUN_ID}."

REQUIRE_MANUAL_CONFIRM=true \
FAIL_IF_AUTO_APPLY=true \
SUCCESS_STATUSES="planned_and_finished,applied" \
TERMINAL_FAILURE_STATUSES="errored,canceled,discarded,force_canceled" \
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-7200}" \
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}" \
.github/scripts/tfc/wait_for_tfc_run.sh "${RUN_ID}" "${TFC_WORKSPACE}"
