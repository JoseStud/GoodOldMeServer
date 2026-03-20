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

detect_public_ip() {
  local family="$1"
  local url="$2"
  local label="$3"
  local ip=""
  local curl_family_flag=""

  case "${family}" in
    4)
      curl_family_flag="--ipv4"
      ;;
    6)
      curl_family_flag="--ipv6"
      ;;
    *)
      echo "Unsupported IP family requested for runner public IP detection: ${family}" >&2
      exit 1
      ;;
  esac

  if ! ip="$(curl "${curl_family_flag}" -fsS --retry 3 --retry-delay 1 --max-time 10 "${url}")"; then
    echo "Failed to resolve runner ${label} public IP for required network preflight."
    exit 1
  fi

  echo "${ip}"
}

should_check_ssh="false"
if [[ "${RUN_ANSIBLE}" == "true" || "${RUN_HOST_SYNC}" == "true" || "${RUN_CONFIG}" == "true" ]]; then
  should_check_ssh="true"
fi

should_check_portainer="false"
if [[ "${RUN_HEALTH}" == "true" || "${RUN_PORTAINER}" == "true" ]]; then
  should_check_portainer="true"
fi

required_oci_ssh="false"
declare -a hosts=()

is_ipv4_literal() {
  local value="$1"
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

if [[ "${should_check_ssh}" == "true" ]]; then
  if ! command -v nc >/dev/null 2>&1; then
    echo "nc (netcat) is required but was not found in PATH."
    exit 1
  fi

  if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "Inventory file not found for SSH preflight: ${INVENTORY_FILE}"
    exit 1
  fi

  if ! command -v yq >/dev/null 2>&1; then
    echo "yq is required for inventory parsing but was not found in PATH."
    exit 1
  fi

  mapfile -t hosts < <(yq -r '.. | .ansible_host? // empty' "${INVENTORY_FILE}")
  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "No ansible_host entries found in ${INVENTORY_FILE}."
    exit 1
  fi

  for host in "${hosts[@]}"; do
    if is_ipv4_literal "${host}"; then
      required_oci_ssh="true"
      break
    fi
  done
fi

runner_ipv4=""
if [[ "${required_oci_ssh}" == "true" ]]; then
  runner_ipv4="$(detect_public_ip 4 "https://api.ipify.org" "IPv4")"
fi

# portainer_api CIDR check removed: PORTAINER_API_URL now uses a Tailscale IP
# accessed via the Dagger pipeline SOCKS5 proxy. No public IP allowlist applies.
python3 - "${NETWORK_ACCESS_POLICY_JSON}" "${runner_ipv4}" "${required_oci_ssh}" <<'PY'
import ipaddress
import json
import sys

policy = json.loads(sys.argv[1])
runner_v4 = ipaddress.ip_address(sys.argv[2]) if sys.argv[2] else None
need_oci_ssh = sys.argv[3] == "true"

def in_ranges(ip, ranges):
    return any(ip in ipaddress.ip_network(raw, strict=False) for raw in ranges)

if need_oci_ssh:
    if not policy["oci_ssh"]["enabled"]:
        raise SystemExit("network_access_policy.oci_ssh.enabled is false but the current run requires IPv4 SSH access.")
    if runner_v4 is None:
        raise SystemExit("Runner IPv4 egress could not be resolved for required OCI SSH preflight.")
    if not in_ranges(runner_v4, policy["oci_ssh"]["source_ranges"]):
        raise SystemExit("Runner IPv4 egress is not in network_access_policy.oci_ssh.source_ranges.")
PY

if [[ -n "${runner_ipv4}" ]]; then
  echo "Runner egress policy check passed: IPv4=${runner_ipv4}"
fi

if [[ "${should_check_ssh}" == "true" ]]; then
  for host in "${hosts[@]}"; do
    nc -z -w5 "${host}" 22
  done
  echo "SSH reachability preflight passed for all inventory hosts."
fi

if [[ "${should_check_portainer}" == "true" ]]; then
  if [[ -z "${PORTAINER_API_URL}" ]]; then
    echo "PORTAINER_API_URL is required for Portainer API preflight."
    exit 1
  fi

  target_url="${PORTAINER_API_URL%/}"
  target_url="${target_url%/api}"

  status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "${target_url}/api/system/status" || true)"
  if [[ "${status}" != "200" && "${status}" != "401" ]]; then
    echo "Portainer API preflight failed (expected 200 or 401, got ${status})."
    exit 1
  fi
  echo "Portainer API preflight passed (HTTP ${status})."
fi
