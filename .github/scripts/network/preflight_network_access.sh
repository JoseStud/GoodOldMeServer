#!/usr/bin/env bash

set -euo pipefail

: "${NETWORK_ACCESS_POLICY_JSON:?NETWORK_ACCESS_POLICY_JSON is required}"

RUN_ANSIBLE="${RUN_ANSIBLE:-false}"
RUN_HOST_SYNC="${RUN_HOST_SYNC:-false}"
RUN_CONFIG="${RUN_CONFIG:-false}"
RUN_HEALTH="${RUN_HEALTH:-false}"
RUN_PORTAINER="${RUN_PORTAINER:-false}"
INVENTORY_FILE="${INVENTORY_FILE:-inventory-ci.yml}"
PORTAINER_API_URL="${PORTAINER_API_URL:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH."
  exit 1
fi

if ! command -v nc >/dev/null 2>&1; then
  echo "nc (netcat) is required but was not found in PATH."
  exit 1
fi

runner_ipv4="$(curl -4 -fsS --retry 3 --retry-delay 1 --max-time 10 https://api.ipify.org)"
runner_ipv6="$(curl -6 -fsS --retry 3 --retry-delay 1 --max-time 10 https://api64.ipify.org)"

python3 - "${NETWORK_ACCESS_POLICY_JSON}" "${runner_ipv4}" "${runner_ipv6}" <<'PY'
import ipaddress
import json
import sys

policy = json.loads(sys.argv[1])
runner_v4 = ipaddress.ip_address(sys.argv[2])
runner_v6 = ipaddress.ip_address(sys.argv[3])

def in_ranges(ip, ranges):
    return any(ip in ipaddress.ip_network(raw, strict=False) for raw in ranges)

if not in_ranges(runner_v4, policy["oci_ssh"]["source_ranges"]):
    raise SystemExit("Runner IPv4 egress is not in network_access_policy.oci_ssh.source_ranges.")
if not in_ranges(runner_v6, policy["gcp_ssh"]["source_ranges"]):
    raise SystemExit("Runner IPv6 egress is not in network_access_policy.gcp_ssh.source_ranges.")
if not (in_ranges(runner_v4, policy["portainer_api"]["source_ranges"]) and in_ranges(runner_v6, policy["portainer_api"]["source_ranges"])):
    raise SystemExit("Runner egress is not fully covered by network_access_policy.portainer_api.source_ranges.")
PY

echo "Runner egress policy check passed: IPv4=${runner_ipv4}, IPv6=${runner_ipv6}"

should_check_ssh="false"
if [[ "${RUN_ANSIBLE}" == "true" || "${RUN_HOST_SYNC}" == "true" || "${RUN_CONFIG}" == "true" ]]; then
  should_check_ssh="true"
fi

if [[ "${should_check_ssh}" == "true" ]]; then
  if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "Inventory file not found for SSH preflight: ${INVENTORY_FILE}"
    exit 1
  fi

  mapfile -t hosts < <(awk '/ansible_host:/ {gsub(/"/, "", $2); print $2}' "${INVENTORY_FILE}")
  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "No ansible_host entries found in ${INVENTORY_FILE}."
    exit 1
  fi

  for host in "${hosts[@]}"; do
    if [[ "${host}" == *:* ]]; then
      nc -6 -z -w5 "${host}" 22
    else
      nc -4 -z -w5 "${host}" 22
    fi
  done
  echo "SSH reachability preflight passed for all inventory hosts."
fi

should_check_portainer="false"
if [[ "${RUN_HEALTH}" == "true" || "${RUN_PORTAINER}" == "true" ]]; then
  should_check_portainer="true"
fi

if [[ "${should_check_portainer}" == "true" ]]; then
  if [[ -z "${PORTAINER_API_URL}" ]]; then
    echo "PORTAINER_API_URL is required for Portainer API preflight."
    exit 1
  fi

  status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "${PORTAINER_API_URL%/}/api/system/status" || true)"
  if [[ "${status}" != "200" && "${status}" != "401" ]]; then
    echo "Portainer API preflight failed (expected 200 or 401, got ${status})."
    exit 1
  fi
  echo "Portainer API preflight passed (HTTP ${status})."
fi
