#!/usr/bin/env bash
# Stage wrapper: reconcile Cloudflare round-robin DNS A records for all
# hostnames declared in Traefik Host(...) router rules in portainer-managed
# stacks. Fetches OCI public IPs from TFC outputs and syncs one record set
# per unique hostname using scripts/cloudflare-dns.sh.

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

TFC_WORKSPACE_INFRA="${TFC_WORKSPACE_INFRA:-goodoldme-infra}"
TFC_API_URL="${TFC_API_URL:-https://app.terraform.io/api/v2}"
STACKS_MANIFEST="${STACKS_MANIFEST:-stacks/stacks.yaml}"
DNS_SYNC_INCLUDE_LEGACY_STACK_NAMES="${DNS_SYNC_INCLUDE_LEGACY_STACK_NAMES:-false}"
DNS_SYNC_EXTRACT_ONLY="${DNS_SYNC_EXTRACT_ONLY:-false}"

declare -A UNIQUE_HOST_MAP=()
declare -a UNIQUE_HOSTS=()

normalize_host_token() {
    local token="$1"
    local host

    # Trim leading/trailing whitespace.
    host="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"${token}")"
    # Remove surrounding quotes/backticks.
    host="${host#\"}"
    host="${host%\"}"
    host="${host#\'}"
    host="${host%\'}"
    host="${host#\`}"
    host="${host%\`}"

    if [[ -z "${host}" ]]; then
        return 1
    fi

    # Expand BASE_DOMAIN references used in compose labels.
    host="${host//\$\{BASE_DOMAIN\}/${BASE_DOMAIN}}"
    host="${host//\$BASE_DOMAIN/${BASE_DOMAIN}}"

    if [[ "${host}" == *'$'* ]]; then
        echo "Warning: skipping unresolved host token '${token}'" >&2
        return 1
    fi

    host="${host,,}"

    # Convert FQDN under BASE_DOMAIN into subdomain label for cloudflare-dns.sh.
    if [[ "${host}" == "${BASE_DOMAIN}" ]]; then
        echo "Warning: skipping apex host '${host}' (only subdomains are supported)" >&2
        return 1
    fi

    if [[ "${host}" == *."${BASE_DOMAIN}" ]]; then
        host="${host%.${BASE_DOMAIN}}"
    fi

    if [[ -z "${host}" || "${host}" == *.* ]]; then
        echo "Warning: skipping unsupported host '${host}'" >&2
        return 1
    fi

    printf '%s\n' "${host}"
}

add_unique_host() {
    local host="$1"
    if [[ -z "${UNIQUE_HOST_MAP[${host}]+_}" ]]; then
        UNIQUE_HOST_MAP["${host}"]=1
        UNIQUE_HOSTS+=("${host}")
    fi
}

extract_hosts_from_rule() {
    local rule="$1"
    local cleaned_rule
    local host_groups
    local group

    # Normalize quoting so Host(...) extraction is consistent.
    cleaned_rule="${rule//\"/\`}"
    cleaned_rule="${cleaned_rule//\'/\`}"

    host_groups="$(grep -oE 'Host\([^)]*\)' <<<"${cleaned_rule}" || true)"
    if [[ -z "${host_groups}" ]]; then
        return
    fi

    while IFS= read -r group; do
        local inner
        inner="${group#Host(}"
        inner="${inner%)}"

        # Ignore Path(...) fragments by only parsing Host(...) groups.
        IFS=',' read -ra candidates <<<"${inner}"
        for candidate in "${candidates[@]}"; do
            local normalized
            if normalized="$(normalize_host_token "${candidate}")"; then
                add_unique_host "${normalized}"
            fi
        done
    done <<<"${host_groups}"
}

extract_hosts_from_compose() {
    local compose_file="$1"
    local label_lines

    if [[ ! -f "${compose_file}" ]]; then
        echo "Error: compose file not found: ${compose_file}" >&2
        return 1
    fi

    # Support list and map label syntaxes by scanning label lines directly.
    label_lines="$(grep -E 'traefik\.http\.routers\..*\.rule' "${compose_file}" || true)"
    if [[ -z "${label_lines}" ]]; then
        return
    fi

    while IFS= read -r line; do
        local rule
        rule="$(sed -E 's/.*traefik\.http\.routers\.[^[:space:]=:]+\.rule[=:][[:space:]]*//' <<<"${line}")"
        rule="${rule%\"}"
        rule="${rule#\"}"
        if [[ -n "${rule}" ]]; then
            extract_hosts_from_rule "${rule}"
        fi
    done <<<"${label_lines}"
}

extract_managed_hosts() {
    local manifest_dir
    manifest_dir="$(dirname "${STACKS_MANIFEST}")"

    require_command yq

    mapfile -t stack_entries < <(
        yq -r '.stacks | to_entries[] | [.key, .value.compose_path] | @tsv' "${STACKS_MANIFEST}"
    )

    if [[ ${#stack_entries[@]} -eq 0 ]]; then
        echo "Error: No stacks found in ${STACKS_MANIFEST}." >&2
        return 1
    fi

    for entry in "${stack_entries[@]}"; do
        local stack
        local compose_rel
        local compose_abs

        stack="${entry%%$'\t'*}"
        compose_rel="${entry#*$'\t'}"
        compose_abs="${manifest_dir}/${compose_rel}"

        extract_hosts_from_compose "${compose_abs}"

        if [[ "${DNS_SYNC_INCLUDE_LEGACY_STACK_NAMES}" == "true" ]]; then
            add_unique_host "${stack}"
        fi
    done

    if [[ ${#UNIQUE_HOSTS[@]} -eq 0 ]]; then
        echo "Error: No Traefik Host(...) hostnames were found in stacks." >&2
        return 1
    fi
}

tfc_api_get() {
    curl -sSfL \
        -H "Authorization: Bearer ${TFC_TOKEN}" \
        -H "Content-Type: application/vnd.api+json" \
        "$1"
}

fetch_oci_ips() {
    local workspace_json
    local workspace_id
    local state_json
    local outputs_url
    local outputs_json
    local oci_ips_json

    workspace_json="$(tfc_api_get "${TFC_API_URL}/organizations/${TFC_ORGANIZATION}/workspaces/${TFC_WORKSPACE_INFRA}")"
    workspace_id="$(jq -r '.data.id // empty' <<<"${workspace_json}")"
    if [[ -z "${workspace_id}" ]]; then
        echo "Error: Failed to resolve TFC workspace id for '${TFC_WORKSPACE_INFRA}'." >&2
        return 1
    fi

    state_json="$(tfc_api_get "${TFC_API_URL}/workspaces/${workspace_id}/current-state-version")"
    outputs_url="$(jq -r '.data.relationships.outputs.links.related // empty' <<<"${state_json}")"
    if [[ -z "${outputs_url}" ]]; then
        echo "Error: No state outputs URL found for workspace '${TFC_WORKSPACE_INFRA}'." >&2
        return 1
    fi

    if [[ "${outputs_url}" == /* ]]; then
        outputs_url="${TFC_API_URL%%/api/*}${outputs_url}"
    fi

    outputs_json="$(tfc_api_get "${outputs_url}")"
    oci_ips_json="$(jq -c '.data[] | select(.attributes.name == "oci_public_ips") | .attributes.value // empty' <<<"${outputs_json}")"
    if [[ -z "${oci_ips_json}" || "${oci_ips_json}" == "null" ]]; then
        echo "Error: TFC output 'oci_public_ips' is missing." >&2
        return 1
    fi

    mapfile -t OCI_IPS < <(jq -r '.[]' <<<"${oci_ips_json}")
    if [[ ${#OCI_IPS[@]} -eq 0 ]]; then
        echo "Error: TFC output 'oci_public_ips' is empty." >&2
        return 1
    fi
}

main() {
    if [[ "${DNS_SYNC_EXTRACT_ONLY}" == "true" ]]; then
        : "${BASE_DOMAIN:?BASE_DOMAIN is required in DNS_SYNC_EXTRACT_ONLY mode}"
        extract_managed_hosts
        printf '%s\n' "${UNIQUE_HOSTS[@]}" | sort
        return 0
    fi

    : "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
    : "${TFC_TOKEN:?TFC_TOKEN is required}"
    : "${TFC_ORGANIZATION:?TFC_ORGANIZATION is required}"

    # ── Infisical login ───────────────────────────────────────────────────────
    setup_infisical

    CLOUDFLARE_API_TOKEN="$(fetch_infisical_secret /infrastructure CLOUDFLARE_API_TOKEN)"
    ZONE_ID="$(fetch_infisical_secret /infrastructure ZONE_ID)"
    BASE_DOMAIN="$(fetch_infisical_secret /infrastructure BASE_DOMAIN)"

    if [[ -z "${CLOUDFLARE_API_TOKEN}" || -z "${ZONE_ID}" || -z "${BASE_DOMAIN}" ]]; then
        echo "Error: One or more required Cloudflare secrets are empty (CLOUDFLARE_API_TOKEN, ZONE_ID, BASE_DOMAIN)." >&2
        return 1
    fi

    export CLOUDFLARE_API_TOKEN ZONE_ID BASE_DOMAIN

    # ── Fetch OCI public IPs from TFC ────────────────────────────────────────
    fetch_oci_ips
    echo "cloudflare-dns-sync: OCI IPs = ${OCI_IPS[*]}"

    # ── Extract hostnames from Traefik Host(...) labels ──────────────────────
    extract_managed_hosts
    mapfile -t sorted_hosts < <(printf '%s\n' "${UNIQUE_HOSTS[@]}" | sort)
    echo "cloudflare-dns-sync: hosts = ${sorted_hosts[*]}"

    # ── Reconcile DNS for each hostname ───────────────────────────────────────
    FAILED=0
    for host in "${sorted_hosts[@]}"; do
        echo "--- ${host} ---"
        if ! bash scripts/cloudflare-dns.sh "${host}" "${OCI_IPS[@]}"; then
            echo "Error: DNS sync failed for host '${host}'." >&2
            FAILED=$((FAILED + 1))
        fi
    done

    if [[ ${FAILED} -gt 0 ]]; then
        echo "cloudflare-dns-sync: ${FAILED} hostname(s) failed." >&2
        return 1
    fi

    echo "cloudflare-dns-sync: complete."
}

main "$@"
