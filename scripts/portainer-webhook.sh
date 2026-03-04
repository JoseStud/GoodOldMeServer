#!/usr/bin/env bash

set -euo pipefail

# Trigger Portainer GitOps webhooks to redeploy stacks.
#
# Portainer natively watches the linked Git repository. Hitting the
# webhook URL tells Portainer "the branch has changed — pull & redeploy".
# No API key, no ENDPOINT_ID — the webhook is bound to the exact stack.
#
# Usage:
#   ./scripts/portainer-webhook.sh <webhook_url>            # single stack
#   ./scripts/portainer-webhook.sh <url1> <url2> ...        # multiple stacks
#   WEBHOOK_URLS="url1,url2" ./scripts/portainer-webhook.sh # via env var (comma-separated)
#
# Environment Variables (optional):
#   WEBHOOK_URLS   Comma-separated list of webhook URLs (used when no args given)

urls=()

if [[ $# -gt 0 ]]; then
  urls=("$@")
elif [[ -n "${WEBHOOK_URLS:-}" ]]; then
  IFS=',' read -ra urls <<< "$WEBHOOK_URLS"
else
  echo "Usage: $0 <webhook_url> [webhook_url ...]"
  echo "  or set WEBHOOK_URLS=url1,url2,..."
  exit 1
fi

failed=0

for url in "${urls[@]}"; do
  url="$(echo "$url" | xargs)"  # trim whitespace
  [[ -z "$url" ]] && continue

  echo "Triggering webhook: ${url##*/}..."  # print only the UUID portion
  HTTP_STATUS=$(curl -sSo /dev/null -w "%{http_code}" -X POST "$url")

  if [[ "$HTTP_STATUS" -eq 204 || "$HTTP_STATUS" -eq 200 ]]; then
    echo "  ✓ Success (HTTP $HTTP_STATUS)"
  else
    echo "  ✗ Failed  (HTTP $HTTP_STATUS)"
    ((failed++))
  fi
done

if [[ $failed -gt 0 ]]; then
  echo ""
  echo "$failed webhook(s) failed."
  exit 1
fi

echo ""
echo "All webhooks triggered successfully."
