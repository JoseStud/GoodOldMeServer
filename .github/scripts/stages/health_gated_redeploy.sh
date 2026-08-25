#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

checkout_stacks_sha "${STACKS_SHA:-}"
setup_infisical

exit_if_shadow_mode "SHADOW_MODE=true: skipping webhook trigger mutations."

# trigger_webhooks_with_gates.sh renders healthcheck_url templates (e.g.
# "https://gateway-health.{{ .Env.BASE_DOMAIN }}/healthz") via gomplate,
# which needs BASE_DOMAIN as a plain env var — it lives under /infrastructure,
# not /deployments (where the WEBHOOK_URL_* secrets are), so fetch it
# separately and export it into the wrapped command's environment.
export BASE_DOMAIN="$(fetch_infisical_secret /infrastructure BASE_DOMAIN)"

infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/deployments -- bash -lc '
  .github/scripts/stacks/trigger_webhooks_with_gates.sh stacks/stacks.yaml
'
