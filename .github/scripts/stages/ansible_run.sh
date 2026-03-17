#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
: "${INVENTORY_FILE:?INVENTORY_FILE is required}"

ANSIBLE_TAGS="${ANSIBLE_TAGS:-}"
TAILSCALE_PEER_WAIT_SECONDS="${TAILSCALE_PEER_WAIT_SECONDS:-600}"
TAILSCALE_PEER_POLL_INTERVAL="${TAILSCALE_PEER_POLL_INTERVAL:-15}"

# For non-IP ansible_host values (e.g. Tailscale MagicDNS short names), resolve
# the peer's Tailscale IP via 'tailscale ip' and patch the inventory in-place.
# MagicDNS short-name resolution is unreliable on CI runners; querying the
# Tailscale daemon directly avoids DNS entirely and works as soon as the peer
# joins the tailnet.
patch_tailscale_hostnames() {
  local inventory_file="$1"

  if ! command -v tailscale >/dev/null 2>&1; then
    echo "tailscale CLI not available, skipping Tailscale hostname resolution"
    return 0
  fi

  # Collect unique non-IP ansible_host values from the inventory.
  local -a hostnames
  mapfile -t hostnames < <(
    grep 'ansible_host:' "$inventory_file" \
      | awk '{print $2}' \
      | tr -d '"' \
      | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -u
  )

  if [[ ${#hostnames[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Resolving Tailscale hostnames: ${hostnames[*]}"

  local hostname ts_ip host_elapsed
  for hostname in "${hostnames[@]}"; do
    ts_ip=""
    host_elapsed=0

    while [[ -z "$ts_ip" && $host_elapsed -lt $TAILSCALE_PEER_WAIT_SECONDS ]]; do
      ts_ip="$(tailscale ip -4 "$hostname" 2>/dev/null || true)"
      if [[ -z "$ts_ip" ]]; then
        echo "Waiting for Tailscale peer '$hostname'... (${host_elapsed}s / ${TAILSCALE_PEER_WAIT_SECONDS}s)"
        sleep "$TAILSCALE_PEER_POLL_INTERVAL"
        host_elapsed=$((host_elapsed + TAILSCALE_PEER_POLL_INTERVAL))
      fi
    done

    if [[ -z "$ts_ip" ]]; then
      echo "ERROR: Tailscale peer '$hostname' not found after ${TAILSCALE_PEER_WAIT_SECONDS}s." >&2
      echo "Ensure cloud-init completed on the node and that TAILSCALE_AUTH_KEY in Infisical is a valid reusable key." >&2
      return 1
    fi

    echo "Resolved $hostname -> $ts_ip (patching inventory)"
    sed -i "s|ansible_host: \"${hostname}\"|ansible_host: \"${ts_ip}\"|g" "$inventory_file"
  done
}

checkout_stacks_sha "${STACKS_SHA:-}"
setup_infisical
generate_ephemeral_ssh_certificate

ansible-galaxy collection install -r ansible/requirements.yml

exit_if_shadow_mode "SHADOW_MODE=true: skipping Ansible mutation run."

patch_tailscale_hostnames "${INVENTORY_FILE}"

ansible_args=(-i "${INVENTORY_FILE}" ansible/playbooks/provision.yml)
if [[ -n "${ANSIBLE_TAGS}" ]]; then
  ansible_args+=(--tags "${ANSIBLE_TAGS}")
fi

ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-30}" \
ANSIBLE_ROLES_PATH=ansible/roles \
ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=accept-new -o CertificateFile=~/.ssh/id_ed25519-cert.pub -i ~/.ssh/id_ed25519' \
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --recursive -- \
  ansible-playbook "${ansible_args[@]}"
