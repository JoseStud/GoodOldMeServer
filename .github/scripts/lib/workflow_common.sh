#!/usr/bin/env bash

set -euo pipefail

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command not found: ${cmd}"
    exit 1
  fi
}

infisical_oidc_login() {
  : "${INFISICAL_MACHINE_IDENTITY_ID:?INFISICAL_MACHINE_IDENTITY_ID is required}"
  infisical login --method=oidc --oidc-client-id="${INFISICAL_MACHINE_IDENTITY_ID}" --domain="${INFISICAL_DOMAIN:-https://app.infisical.com}"
}

setup_infisical() {
  require_command infisical
  infisical_oidc_login
}

checkout_stacks_sha() {
  local stacks_sha="${1:-}"
  if [[ -z "${stacks_sha}" ]]; then
    return
  fi

  git -C stacks fetch --depth=1 origin "${stacks_sha}"
  git -C stacks checkout --detach "${stacks_sha}"
}

generate_ephemeral_ssh_certificate() {
  : "${INFISICAL_SSH_CA_ID:?INFISICAL_SSH_CA_ID is required}"
  require_command ssh-keygen
  require_command infisical
  mkdir -p ~/.ssh
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  infisical ssh sign --public-key=~/.ssh/id_ed25519.pub --ca-id="${INFISICAL_SSH_CA_ID}" > ~/.ssh/id_ed25519-cert.pub
}
