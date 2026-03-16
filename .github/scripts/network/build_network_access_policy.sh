#!/usr/bin/env bash

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

detect_public_ip() {
  local family="$1"
  local url="$2"
  curl "-${family}" -fsS --retry 3 --retry-delay 1 --max-time 10 "${url}"
}

validate_policy_shape() {
  local policy_json="$1"
  jq -e '
    . as $p
    | ($p | type) == "object"
    | . and ($p.oci_ssh | type) == "object"
    | . and ($p.portainer_api | type) == "object"
    | . and ($p.oci_ssh.enabled | type) == "boolean"
    | . and ($p.oci_ssh.source_ranges | type) == "array"
    | . and ($p.portainer_api.source_ranges | type) == "array"
    | . and ($p.portainer_api.source_ranges | length) > 0
  ' <<<"${policy_json}" >/dev/null
}

validate_policy_families() {
  local policy_json="$1"
  python3 - "${policy_json}" <<'PY'
import ipaddress
import json
import sys

policy = json.loads(sys.argv[1])

def check_ranges(name, ranges, family, allow_empty=False):
    if not ranges and not allow_empty:
        raise ValueError(f"{name}.source_ranges must not be empty")
    for raw in ranges:
        try:
            net = ipaddress.ip_network(raw, strict=False)
        except ValueError as exc:
            raise ValueError(f"{name}.source_ranges contains invalid CIDR '{raw}': {exc}") from exc
        if family == "ipv4" and net.version != 4:
            raise ValueError(f"{name}.source_ranges must contain only IPv4 CIDRs: '{raw}'")
        if family == "ipv6" and net.version != 6:
            raise ValueError(f"{name}.source_ranges must contain only IPv6 CIDRs: '{raw}'")

check_ranges("oci_ssh", policy["oci_ssh"]["source_ranges"], "ipv4", allow_empty=not policy["oci_ssh"]["enabled"])
check_ranges("portainer_api", policy["portainer_api"]["source_ranges"], "ipv4")
PY
}

BREAK_GLASS_POLICY_JSON="${BREAK_GLASS_POLICY_JSON:-}"
BREAK_GLASS_POLICY_FILE="${BREAK_GLASS_POLICY_FILE:-}"

policy_json=""
if [[ -n "${BREAK_GLASS_POLICY_FILE}" ]]; then
  if [[ ! -f "${BREAK_GLASS_POLICY_FILE}" ]]; then
    echo "Break-glass policy file not found: ${BREAK_GLASS_POLICY_FILE}"
    exit 1
  fi
  policy_json="$(cat "${BREAK_GLASS_POLICY_FILE}")"
  echo "Using break-glass policy file: ${BREAK_GLASS_POLICY_FILE}"
elif [[ -n "${BREAK_GLASS_POLICY_JSON}" ]]; then
  policy_json="${BREAK_GLASS_POLICY_JSON}"
  echo "Using break-glass policy from workflow input."
else
  runner_ipv4="$(detect_public_ip 4 "https://api.ipify.org")"
  policy_json="$(
    jq -cn \
      --arg ipv4 "${runner_ipv4}/32" \
      '{
        oci_ssh: { enabled: true, source_ranges: [$ipv4] },
        portainer_api: { source_ranges: [$ipv4] }
      }'
  )"
fi

validate_policy_shape "${policy_json}"
validate_policy_families "${policy_json}"

policy_json="$(jq -cS '.' <<<"${policy_json}")"
portainer_cidrs_csv="$(jq -r '.portainer_api.source_ranges | join(",")' <<<"${policy_json}")"
oci_ssh_cidrs_csv="$(jq -r '.oci_ssh.source_ranges | join(",")' <<<"${policy_json}")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "network_access_policy_json=${policy_json}"
    echo "portainer_automation_allowed_cidrs=${portainer_cidrs_csv}"
    echo "oci_ssh_source_ranges=${oci_ssh_cidrs_csv}"
  } >>"${GITHUB_OUTPUT}"
fi

echo "${policy_json}"
