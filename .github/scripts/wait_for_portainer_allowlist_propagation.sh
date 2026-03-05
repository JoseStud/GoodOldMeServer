#!/usr/bin/env bash

set -euo pipefail

: "${PORTAINER_API_URL:?PORTAINER_API_URL is required}"

WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-420}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
endpoint="${PORTAINER_API_URL%/}/api/system/status"

deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
last_status="000"

echo "Waiting for Portainer API allowlist propagation at ${endpoint}"
while (( SECONDS < deadline )); do
  last_status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "${endpoint}" || true)"

  case "${last_status}" in
    200|401)
      echo "Portainer API reachable after allowlist propagation (HTTP ${last_status})."
      exit 0
      ;;
    403)
      echo "Portainer API still blocked by allowlist (HTTP 403), waiting..."
      ;;
    *)
      echo "Portainer API not ready yet (HTTP ${last_status}), waiting..."
      ;;
  esac

  sleep "${POLL_INTERVAL_SECONDS}"
done

echo "Timed out waiting for Portainer API allowlist propagation. Last status: ${last_status}."
exit 1
