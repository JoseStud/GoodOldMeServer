#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

apt_install jq netcat-openbsd

RUN_ANSIBLE="${RUN_ANSIBLE:-false}" \
RUN_CONFIG="${RUN_CONFIG:-false}" \
RUN_HEALTH="false" \
RUN_PORTAINER="false" \
INVENTORY_FILE="${INVENTORY_FILE:-inventory-ci.yml}" \
.github/scripts/network/preflight_network_access.sh
