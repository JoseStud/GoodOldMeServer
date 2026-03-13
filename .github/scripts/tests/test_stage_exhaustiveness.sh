#!/usr/bin/env bash
# Verifies that every stage_* key emitted by the ci_plan Python package is consumed
# by at least one job's `if:` condition in the reusable orchestrator workflows.
# This ensures that adding a new stage flag without wiring it into a workflow
# causes a CI failure rather than a silent no-op.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

WORKFLOW_DIR="${ROOT_DIR}/.github/workflows"

REUSABLE_WORKFLOWS=(
  "${WORKFLOW_DIR}/reusable-orch-preflight.yml"
  "${WORKFLOW_DIR}/reusable-orch-infra.yml"
  "${WORKFLOW_DIR}/reusable-orch-ansible.yml"
  "${WORKFLOW_DIR}/reusable-orch-portainer.yml"
)

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Extract stage field names from the Python Stages dataclass.
# Requires ci_plan package to be installed (pip install .github/scripts/plan/).
mapfile -t stage_keys < <(
  python3 -c "
from dataclasses import fields
from ci_plan.models import Stages
for f in fields(Stages):
    print(f.name)
"
)

if [[ ${#stage_keys[@]} -eq 0 ]]; then
  echo "ERROR: no stage_* keys found in ci_plan.models.Stages"
  exit 1
fi

echo "Found ${#stage_keys[@]} stage keys: ${stage_keys[*]}"

# Concatenate all reusable workflow files for searching.
combined_workflows="${WORKFLOW_DIR}/_exhaustiveness_check_combined.tmp"
trap 'rm -f "${combined_workflows}"' EXIT
cat "${REUSABLE_WORKFLOWS[@]}" > "${combined_workflows}"

for key in "${stage_keys[@]}"; do
  if grep -qF "stages.${key}" "${combined_workflows}"; then
    pass "${key} is consumed by a reusable workflow"
  else
    fail "${key} is NOT consumed by any reusable workflow (reusable-orch-*.yml)"
  fi
done

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
