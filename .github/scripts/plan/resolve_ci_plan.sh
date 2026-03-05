#!/usr/bin/env bash
# Thin dispatcher: routes to the mode-specific resolver script.

set -euo pipefail

: "${CI_PLAN_MODE:?CI_PLAN_MODE is required}"
: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${CI_PLAN_MODE}" in
  meta)
    source "${SCRIPT_DIR}/resolve_meta_plan.sh"
    resolve_meta_mode
    ;;
  iac)
    source "${SCRIPT_DIR}/resolve_iac_plan.sh"
    resolve_iac_mode
    ;;
  *)
    echo "Unsupported CI_PLAN_MODE: ${CI_PLAN_MODE}"
    exit 1
    ;;
esac

