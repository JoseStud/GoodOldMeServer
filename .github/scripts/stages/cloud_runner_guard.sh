#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${CLOUD_STATIC_RUNNER_LABEL:?Missing required variable: CLOUD_STATIC_RUNNER_LABEL}"
: "${INFISICAL_TOKEN:?Missing required secret: INFISICAL_TOKEN}"

echo "runner_label=${CLOUD_STATIC_RUNNER_LABEL}" >> "${GITHUB_OUTPUT}"
