#!/usr/bin/env bash

set -e

# Required Environment Variables:
# BASE_DOMAIN (e.g., example.com)
# PORTAINER_TOKEN (Access Token from Portainer)
# ENDPOINT_ID (Often 1 for local)

STACK_NAME=$1
ENV_FILE=$2

if [ -z "$STACK_NAME" ] || [ -z "$ENV_FILE" ]; then
    echo "Usage: $0 <stack_name> <env_file_path>"
    exit 1
fi

if [ -z "$BASE_DOMAIN" ] || [ -z "$PORTAINER_TOKEN" ]; then
    echo "Error: BASE_DOMAIN and PORTAINER_TOKEN environment variables must be set."
    exit 1
fi

PORTAINER_URL="https://portainer.${BASE_DOMAIN}"
ENDPOINT_ID=${ENDPOINT_ID:-1}

# 1. Read .env file into Portainer JSON format
# Skips empty lines and comments, splits on first '=' only
ENV_JSON=$(grep -v '^#' "$ENV_FILE" | grep -v '^$' | while IFS= read -r line; do
  key="${line%%=*}"
  val="${line#*=}"
  # Strip surrounding quotes if present
  val="${val#\"}"
  val="${val%\"}"
  # Escape inner double quotes for JSON
  val="${val//\"/\\\"}"
  printf '{"name": "%s", "value": "%s"},' "$key" "$val"
done | sed 's/,$//')

ENV_JSON="[${ENV_JSON}]"

echo "Fetching stack $STACK_NAME from Portainer..."
# 2. Get Stack ID by Name
STACKS_JSON=$(curl -s -H "X-API-Key: ${PORTAINER_TOKEN}" "${PORTAINER_URL}/api/stacks")
STACK_ID=$(echo "$STACKS_JSON" | jq -r ".[] | select(.Name == \"$STACK_NAME\") | .Id")

if [ -z "$STACK_ID" ] || [ "$STACK_ID" == "null" ]; then
    echo "Error: Stack '$STACK_NAME' not found in Portainer."
    exit 1
fi

echo "Stack ID for '$STACK_NAME' is $STACK_ID. Fetching stack details..."

# 3. Get existing stack details to keep Git settings intact
STACK_DETAILS=$(curl -s -H "X-API-Key: ${PORTAINER_TOKEN}" "${PORTAINER_URL}/api/stacks/$STACK_ID")

# We only need to tell Portainer to pull from Git again and update env vars
# Portainer's PUT /api/stacks/{id}/git endpoint updates Git stacks.
# Usually PUT /api/stacks/{id}/git re-pulls and updates.
# Wait, updating env vars might require PUT /api/stacks/{id}

PAYLOAD=$(cat <<EOF
{
  "env": ${ENV_JSON}
}
EOF
)

echo "Updating stack $STACK_NAME..."

RESPONSE=$(curl -s -o /tmp/portainer_response.json -w "%{http_code}" -X PUT -H "Content-Type: application/json" -H "X-API-Key: ${PORTAINER_TOKEN}" -d "$PAYLOAD" "${PORTAINER_URL}/api/stacks/$STACK_ID?endpointId=$ENDPOINT_ID")

HTTP_STATUS="$RESPONSE"
BODY=$(cat /tmp/portainer_response.json)
rm -f /tmp/portainer_response.json

if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 204 ]; then
    echo "Successfully updated stack $STACK_NAME."
    exit 0
else
    echo "Failed to update stack $STACK_NAME. HTTP Status: $HTTP_STATUS"
    echo "Response: $BODY"
    exit 1
fi
