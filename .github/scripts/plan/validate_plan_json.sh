#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workflow_common.sh"

validate_plan_json "${PLAN_JSON:-}"
