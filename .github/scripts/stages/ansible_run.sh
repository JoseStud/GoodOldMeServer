#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
: "${INVENTORY_FILE:?INVENTORY_FILE is required}"

ANSIBLE_TAGS="${ANSIBLE_TAGS:-}"
TAILSCALE_PEER_WAIT_SECONDS="${TAILSCALE_PEER_WAIT_SECONDS:-300}"
TAILSCALE_PEER_POLL_INTERVAL="${TAILSCALE_PEER_POLL_INTERVAL:-15}"
RUN_INFRA_APPLY="${RUN_INFRA_APPLY:-false}"
PREFER_TAILSCALE_SSH="${PREFER_TAILSCALE_SSH:-false}"

if [[ "${RUN_INFRA_APPLY}" != "true" ]]; then
  PREFER_TAILSCALE_SSH="true"
fi

emit_tailscale_debug_state() {
  local hostname="${1:-}"

  if ! command -v tailscale >/dev/null 2>&1; then
    return 0
  fi

  echo "Tailscale debug: local status"
  tailscale status || true

  if [[ -n "${hostname}" ]]; then
    echo "Tailscale debug: peer lookup for '${hostname}'"
    tailscale ping -c 1 "${hostname}" || true
    tailscale ip "${hostname}" || true
  fi
}

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

  if [[ "${PREFER_TAILSCALE_SSH}" == "true" ]]; then
    echo "Tailscale priority mode enabled (infra apply skipped)."
    # Include OCI aliases even when ansible_host still contains IPv4 literals.
    local -a oci_aliases
    local alias
    mapfile -t oci_aliases < <(
      grep -E '^[[:space:]]{4}oci-node-[0-9]+:' "$inventory_file" \
        | sed -E 's/^[[:space:]]+([^:]+):/\1/' \
        | sort -u
    )

    for alias in "${oci_aliases[@]}"; do
      if ! printf '%s\n' "${hostnames[@]}" | grep -qx -- "${alias}"; then
        hostnames+=("${alias}")
      fi
    done
  fi

  if [[ ${#hostnames[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Resolving Tailscale hostnames: ${hostnames[*]}"

  local hostname ts_ip host_elapsed lookup_name
  local -a lookup_candidates

  set_inventory_host_ip() {
    local inventory="$1"
    local alias="$2"
    local ip="$3"
    local tmp_file
    tmp_file="$(mktemp)"

    awk -v host="$alias" -v new_ip="$ip" '
      $1 == (host ":") { in_host = 1 }
      in_host == 1 && $1 == "ansible_host:" {
        print "      ansible_host: \"" new_ip "\""
        in_host = 0
        next
      }
      { print }
    ' "$inventory" > "$tmp_file"

    mv "$tmp_file" "$inventory"
  }

  for hostname in "${hostnames[@]}"; do
    ts_ip=""
    host_elapsed=0

    lookup_candidates=("$hostname")
    # OCI migration fallback: inventory now uses oci-node-N. If a node is still
    # registered in Tailscale with its legacy hostname (app-worker-N), probe it
    # before failing.
    if [[ "$hostname" =~ ^oci-node-([0-9]+)$ ]]; then
      lookup_candidates+=("app-worker-${BASH_REMATCH[1]}")
    fi

    while [[ -z "$ts_ip" && $host_elapsed -lt $TAILSCALE_PEER_WAIT_SECONDS ]]; do
      for lookup_name in "${lookup_candidates[@]}"; do
        ts_ip="$(tailscale ip -4 "$lookup_name" 2>/dev/null || true)"
        if [[ -n "$ts_ip" ]]; then
          break
        fi
      done

      if [[ -z "$ts_ip" ]]; then
        echo "Waiting for Tailscale peer '$hostname'... (${host_elapsed}s / ${TAILSCALE_PEER_WAIT_SECONDS}s)"
        sleep "$TAILSCALE_PEER_POLL_INTERVAL"
        host_elapsed=$((host_elapsed + TAILSCALE_PEER_POLL_INTERVAL))
      fi
    done

    if [[ -z "$ts_ip" ]]; then
      echo "ERROR: Tailscale peer '$hostname' not found after ${TAILSCALE_PEER_WAIT_SECONDS}s." >&2
      emit_tailscale_debug_state "$hostname"
      echo "Ensure cloud-init completed on the node and that TAILSCALE_AUTH_KEY in Infisical is a valid reusable key." >&2
      echo "If your tailnet policy requires tag-based SSH (for example dst=tag:server), make sure the auth key is allowed to advertise that tag and the startup script still uses --advertise-tags accordingly." >&2
      echo "If the witness startup script changed, remember that GCE startup scripts rerun on boot, not immediately on metadata update; reboot or recreate the instance to pick up the change." >&2
      return 1
    fi

    echo "Resolved $hostname -> $ts_ip (patching inventory)"
    if [[ "$hostname" =~ ^oci-node-([0-9]+)$ ]]; then
      set_inventory_host_ip "$inventory_file" "$hostname" "$ts_ip"
    else
      sed -i "s|ansible_host: \"${hostname}\"|ansible_host: \"${ts_ip}\"|g" "$inventory_file"
    fi
  done
}

checkout_stacks_sha "${STACKS_SHA:-}"
setup_infisical
generate_ephemeral_ssh_certificate

ansible-galaxy collection install --clear-response-cache -r ansible/requirements.yml

exit_if_shadow_mode "SHADOW_MODE=true: skipping Ansible mutation run."

patch_tailscale_hostnames "${INVENTORY_FILE}"

ansible_args=(-i "${INVENTORY_FILE}" ansible/playbooks/provision.yml)
if [[ -n "${ANSIBLE_TAGS}" ]]; then
  ansible_args+=(--tags "${ANSIBLE_TAGS}")
fi

# Load Infisical secrets from paths needed by the playbook:
#   /infrastructure     → TAILSCALE_AUTH_KEY, BASE_DOMAIN, TZ, etc.
#   /stacks/management  → PORTAINER_ADMIN_PASSWORD, PORTAINER_API_KEY, HOMARR_SECRET_KEY
# infisical run only supports a single --path, so nest two invocations;
# inner process inherits the outer env.
ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-30}" \
ANSIBLE_ROLES_PATH=ansible/roles \
ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=accept-new -o CertificateFile=~/.ssh/id_ed25519-cert.pub -i ~/.ssh/id_ed25519' \
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/infrastructure -- \
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/stacks/management -- \
  ansible-playbook "${ansible_args[@]}"
