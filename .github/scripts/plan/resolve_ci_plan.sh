#!/usr/bin/env bash
# Thin wrapper: delegates to the Python ci_plan package.
# In CI the package is pre-installed by a prior workflow step.
# For local use: pip install .github/scripts/plan/ && .github/scripts/plan/resolve_ci_plan.sh

set -euo pipefail

if ! python3 -c "import ci_plan" 2>/dev/null; then
  echo "ci_plan package not found. Install with: pip install .github/scripts/plan/" >&2
  exit 1
fi

python3 -m ci_plan
