#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${TFC_WORKSPACE_INFRA:?TFC_WORKSPACE_INFRA is required}"
: "${OUTPUT_FILE:?OUTPUT_FILE is required}"

.github/scripts/tfc/render_inventory_from_tfc_outputs.sh "${TFC_WORKSPACE_INFRA}" "${OUTPUT_FILE}"
