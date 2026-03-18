#!/bin/bash
# Description: Declaratively reconcile Cloudflare DNS A records for round-robin.
# Creates missing records, deletes stale records, keeps matching records.
# Subdomain is automatically generated using the Stack Name and Base Domain.
# Requires: curl, jq

set -euo pipefail

# These variables are injected by Infisical from the /infrastructure path
ZONE_ID="${ZONE_ID}"
API_TOKEN="${CLOUDFLARE_API_TOKEN}"
BASE_DOMAIN="${BASE_DOMAIN}"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <STACK_NAME> <IP1> [IP2...]"
    echo "Example: $0 gateway 129.0.0.1 152.0.0.2"
    exit 1
fi

STACK_NAME="$1"
shift
DESIRED_IPS=("$@")

# Validate all IP addresses
for ip in "${DESIRED_IPS[@]}"; do
    if ! echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "Error: '$ip' is not a valid IPv4 address."
        exit 1
    fi
done

RECORD_NAME="${STACK_NAME}.${BASE_DOMAIN}"
RECORD_TYPE="A"
PROXIED="true"
TTL=1

echo "Configuring DNS for Stack: ${STACK_NAME}"
echo "Target: ${RECORD_NAME} -> ${DESIRED_IPS[*]}"
echo "Fetching existing A records..."

# Fetch all existing A records for this hostname
EXISTING_JSON=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${RECORD_TYPE}&name=${RECORD_NAME}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json")

if [ "$(echo "$EXISTING_JSON" | jq -r '.success')" != "true" ]; then
    echo "Error: Failed to fetch existing DNS records."
    echo "$EXISTING_JSON" | jq .
    exit 1
fi

# Build associative map of existing IP -> record ID
declare -A EXISTING_MAP
while IFS=$'\t' read -r record_id record_ip; do
    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        EXISTING_MAP["$record_ip"]="$record_id"
    fi
done < <(echo "$EXISTING_JSON" | jq -r '.result[] | [.id, .content] | @tsv')

CREATED=0
KEPT=0
DELETED=0

# Create records for IPs not yet present
for ip in "${DESIRED_IPS[@]}"; do
    if [ -n "${EXISTING_MAP[$ip]+_}" ]; then
        echo "  kept    ${RECORD_NAME} -> ${ip} (ID: ${EXISTING_MAP[$ip]})"
        KEPT=$((KEPT + 1))
    else
        echo "  creating ${RECORD_NAME} -> ${ip}..."
        PAYLOAD=$(jq -n \
            --arg type "$RECORD_TYPE" \
            --arg name "$RECORD_NAME" \
            --arg content "$ip" \
            --argjson ttl $TTL \
            --argjson proxied "$PROXIED" \
            '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')
        RESPONSE=$(curl -s -X POST \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD")
        if [ "$(echo "$RESPONSE" | jq -r '.success')" = "true" ]; then
            echo "  created ${RECORD_NAME} -> ${ip}"
            CREATED=$((CREATED + 1))
        else
            echo "Error: Failed to create record for ${ip}."
            echo "$RESPONSE" | jq .
            exit 1
        fi
    fi
done

# Delete stale records (existing IPs not in desired set)
for existing_ip in "${!EXISTING_MAP[@]}"; do
    desired=false
    for ip in "${DESIRED_IPS[@]}"; do
        if [ "$ip" = "$existing_ip" ]; then
            desired=true
            break
        fi
    done
    if [ "$desired" = "false" ]; then
        record_id="${EXISTING_MAP[$existing_ip]}"
        echo "  deleting stale ${RECORD_NAME} -> ${existing_ip} (ID: ${record_id})..."
        RESPONSE=$(curl -s -X DELETE \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        if [ "$(echo "$RESPONSE" | jq -r '.success')" = "true" ]; then
            echo "  deleted ${RECORD_NAME} -> ${existing_ip}"
            DELETED=$((DELETED + 1))
        else
            echo "Error: Failed to delete stale record for ${existing_ip}."
            echo "$RESPONSE" | jq .
            exit 1
        fi
    fi
done

echo "Done: ${CREATED} created, ${KEPT} kept, ${DELETED} deleted for ${RECORD_NAME}."
