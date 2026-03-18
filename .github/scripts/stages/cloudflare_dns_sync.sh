#!/usr/bin/env bash
# Stage wrapper: reconcile Cloudflare round-robin DNS A records for all
# portainer-managed stacks.  Fetches OCI public IPs from TFC outputs and
# syncs one record set per stack using scripts/cloudflare-dns.sh.

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
: "${TFC_TOKEN:?TFC_TOKEN is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"

TFC_WORKSPACE_INFRA="${TFC_WORKSPACE_INFRA:-goodoldme-infra}"
TFC_API_URL="${TFC_API_URL:-https://app.terraform.io/api/v2}"
STACKS_MANIFEST="${STACKS_MANIFEST:-stacks/stacks.yaml}"

# ── Infisical login ────────────────────────────────────────────────────────────
setup_infisical

CLOUDFLARE_API_TOKEN="$(fetch_infisical_secret /infrastructure CLOUDFLARE_API_TOKEN)"
ZONE_ID="$(fetch_infisical_secret /infrastructure ZONE_ID)"
BASE_DOMAIN="$(fetch_infisical_secret /infrastructure BASE_DOMAIN)"

if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$ZONE_ID" || -z "$BASE_DOMAIN" ]]; then
    echo "Error: One or more required Cloudflare secrets are empty (CLOUDFLARE_API_TOKEN, ZONE_ID, BASE_DOMAIN)." >&2
    exit 1
fi

export CLOUDFLARE_API_TOKEN ZONE_ID BASE_DOMAIN

# ── Fetch OCI public IPs from TFC ─────────────────────────────────────────────
tfc_api_get() {
    curl -sSfL \
        -H "Authorization: Bearer ${TFC_TOKEN}" \
        -H "Content-Type: application/vnd.api+json" \
        "$1"
}

workspace_json="$(tfc_api_get "${TFC_API_URL}/organizations/${TFC_ORGANIZATION}/workspaces/${TFC_WORKSPACE_INFRA}")"
workspace_id="$(jq -r '.data.id // empty' <<<"${workspace_json}")"
if [[ -z "${workspace_id}" ]]; then
    echo "Error: Failed to resolve TFC workspace id for '${TFC_WORKSPACE_INFRA}'." >&2
    exit 1
fi

state_json="$(tfc_api_get "${TFC_API_URL}/workspaces/${workspace_id}/current-state-version")"
outputs_url="$(jq -r '.data.relationships.outputs.links.related // empty' <<<"${state_json}")"
if [[ -z "${outputs_url}" ]]; then
    echo "Error: No state outputs URL found for workspace '${TFC_WORKSPACE_INFRA}'." >&2
    exit 1
fi

if [[ "${outputs_url}" == /* ]]; then
    outputs_url="${TFC_API_URL%%/api/*}${outputs_url}"
fi

outputs_json="$(tfc_api_get "${outputs_url}")"
oci_ips_json="$(jq -c '.data[] | select(.attributes.name == "oci_public_ips") | .attributes.value // empty' <<<"${outputs_json}")"
if [[ -z "${oci_ips_json}" || "${oci_ips_json}" == "null" ]]; then
    echo "Error: TFC output 'oci_public_ips' is missing." >&2
    exit 1
fi

mapfile -t OCI_IPS < <(jq -r '.[]' <<<"${oci_ips_json}")
if [[ ${#OCI_IPS[@]} -eq 0 ]]; then
    echo "Error: TFC output 'oci_public_ips' is empty." >&2
    exit 1
fi

echo "cloudflare-dns-sync: OCI IPs = ${OCI_IPS[*]}"

# ── Extract portainer-managed stack names from manifest ───────────────────────
require_command yq

mapfile -t STACKS < <(yq '.stacks | to_entries[] | select(.value.portainer_managed == true) | .key' "${STACKS_MANIFEST}")
if [[ ${#STACKS[@]} -eq 0 ]]; then
    echo "Error: No portainer-managed stacks found in ${STACKS_MANIFEST}." >&2
    exit 1
fi

echo "cloudflare-dns-sync: stacks = ${STACKS[*]}"

# ── Reconcile DNS for each stack ──────────────────────────────────────────────
FAILED=0
for stack in "${STACKS[@]}"; do
    echo "--- ${stack} ---"
    if ! bash scripts/cloudflare-dns.sh "${stack}" "${OCI_IPS[@]}"; then
        echo "Error: DNS sync failed for stack '${stack}'." >&2
        ((FAILED++))
    fi
done

if [[ $FAILED -gt 0 ]]; then
    echo "cloudflare-dns-sync: ${FAILED} stack(s) failed." >&2
    exit 1
fi

echo "cloudflare-dns-sync: complete."
