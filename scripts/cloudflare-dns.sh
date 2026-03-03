#!/bin/bash
# Description: Creates or updates a Cloudflare DNS A record using API v4.
# Subdomain is automatically generated using the Stack Name and Base Domain.
# Requires: curl, jq

set -e

# These variables are injected by Infisical from the /infrastructure path
ZONE_ID="${CLOUDFLARE_ZONE_ID}"
API_TOKEN="${CLOUDFLARE_API_TOKEN}"
BASE_DOMAIN="${BASE_DOMAIN}"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <STACK_NAME> <IP_ADDRESS>"
    echo "Example: $0 portainer 192.168.1.50"
    exit 1
fi

STACK_NAME="$1"
IP_ADDRESS="$2"

# Validate IP address format
if ! echo "$IP_ADDRESS" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "Error: '$IP_ADDRESS' is not a valid IPv4 address."
    exit 1
fi

# Automatically construct the subdomain
RECORD_NAME="${STACK_NAME}.${BASE_DOMAIN}"
RECORD_TYPE="A"
PROXIED="true" # Set to false if you just want DNS resolution without Cloudflare proxying
TTL=1 # 1 = Automatic TTL

echo "Configuring DNS for Stack: ${STACK_NAME}"
echo "Target URL: ${RECORD_NAME} -> ${IP_ADDRESS}"
echo "Checking for existing DNS record..."

# 1. Get the Record ID if it exists
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${RECORD_TYPE}&name=${RECORD_NAME}" \
     -H "Authorization: Bearer ${API_TOKEN}" \
     -H "Content-Type: application/json" | jq -r '.result[0].id')

# Build the JSON payload
PAYLOAD=$(cat <<EOF
{
  "type": "${RECORD_TYPE}",
  "name": "${RECORD_NAME}",
  "content": "${IP_ADDRESS}",
  "ttl": ${TTL},
  "proxied": ${PROXIED}
}
EOF
)

if [ "$RECORD_ID" == "null" ] || [ -z "$RECORD_ID" ]; then
    echo "Record does not exist. Creating new A record..."
    # 2. CREATE Record (POST)
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
         -H "Authorization: Bearer ${API_TOKEN}" \
         -H "Content-Type: application/json" \
         -d "${PAYLOAD}")
    
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success')
    if [ "$SUCCESS" = "true" ]; then
        echo "✅ DNS Record Created successfully for ${RECORD_NAME}."
    else
        echo "❌ Failed to create DNS record. API Response:"
        echo "$RESPONSE" | jq .
        exit 1
    fi
else
    echo "Record exists (ID: $RECORD_ID). Updating record..."
    # 3. UPDATE Record (PUT)
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
         -H "Authorization: Bearer ${API_TOKEN}" \
         -H "Content-Type: application/json" \
         -d "${PAYLOAD}")
         
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success')
    if [ "$SUCCESS" = "true" ]; then
        echo "✅ DNS Record Updated successfully for ${RECORD_NAME}."
    else
        echo "❌ Failed to update DNS record. API Response:"
        echo "$RESPONSE" | jq .
        exit 1
    fi
fi
