#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <workspace_name> [output_file]"
  exit 1
fi

WORKSPACE_NAME="$1"
OUTPUT_FILE="${2:-inventory-ci.yml}"
TFC_API_URL="${TFC_API_URL:-https://app.terraform.io/api/v2}"

: "${TFC_TOKEN:?TFC_TOKEN is required}"
: "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"

api_get() {
  local url="$1"
  curl -sSfL \
    -H "Authorization: Bearer ${TFC_TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    "${url}"
}

workspace_json="$(api_get "${TFC_API_URL}/organizations/${TFC_ORGANIZATION}/workspaces/${WORKSPACE_NAME}")"
workspace_id="$(jq -r '.data.id // empty' <<<"${workspace_json}")"
if [[ -z "${workspace_id}" ]]; then
  echo "Failed to resolve Terraform Cloud workspace id for '${WORKSPACE_NAME}'."
  exit 1
fi

state_json="$(api_get "${TFC_API_URL}/workspaces/${workspace_id}/current-state-version")"
outputs_url="$(jq -r '.data.relationships.outputs.links.related // empty' <<<"${state_json}")"
if [[ -z "${outputs_url}" ]]; then
  echo "No state outputs URL found for workspace '${WORKSPACE_NAME}'."
  exit 1
fi

# TFC returns relative URLs in links.related — prepend the host.
if [[ "${outputs_url}" == /* ]]; then
  outputs_url="${TFC_API_URL%%/api/*}${outputs_url}"
fi

outputs_json="$(api_get "${outputs_url}")"

oci_ips_json="$(jq -c '.data[] | select(.attributes.name == "oci_public_ips") | .attributes.value // empty' <<<"${outputs_json}")"
if [[ -z "${oci_ips_json}" || "${oci_ips_json}" == "null" ]]; then
  echo "Workspace output 'oci_public_ips' is missing."
  exit 1
fi

mapfile -t OCI_IPS < <(jq -r '.[]' <<<"${oci_ips_json}")
if [[ ${#OCI_IPS[@]} -eq 0 ]]; then
  echo "Workspace output 'oci_public_ips' is empty."
  exit 1
fi

GCP_WITNESS_HOSTNAME="$(jq -r '.data[] | select(.attributes.name == "gcp_witness_tailscale_hostname") | .attributes.value // empty' <<<"${outputs_json}")"
if [[ -z "${GCP_WITNESS_HOSTNAME}" ]]; then
  echo "Workspace output 'gcp_witness_tailscale_hostname' is missing."
  exit 1
fi

{
  echo "all:"
  echo "  hosts:"
  for i in "${!OCI_IPS[@]}"; do
    host="oci-node-$((i + 1))"
    echo "    ${host}:"
    echo "      ansible_host: \"${OCI_IPS[$i]}\""
    echo "      ansible_user: \"ubuntu\""
  done
  echo "    gcp-witness:"
  echo "      ansible_host: \"${GCP_WITNESS_HOSTNAME}\""
  echo "      ansible_user: \"debian\""
  echo "  children:"
  echo "    oci_nodes:"
  echo "      hosts:"
  for i in "${!OCI_IPS[@]}"; do
    host="oci-node-$((i + 1))"
    echo "        ${host}:"
  done
  echo "    gcp_witness:"
  echo "      hosts:"
  echo "        gcp-witness:"
} > "${OUTPUT_FILE}"

echo "Rendered inventory to ${OUTPUT_FILE}"
