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

apt_install() {
  if [[ $# -eq 0 ]]; then
    return
  fi
  sudo apt-get update
  sudo apt-get install -y "$@"
}

setup_infisical_cli() {
  curl -1sLf 'https://artifacts-infisical-core.infisical.com/setup.deb.sh' | sudo -E bash
  sudo apt-get update
  sudo apt-get install -y infisical-core
}

infisical_oidc_login() {
  : "${INFISICAL_MACHINE_IDENTITY_ID:?INFISICAL_MACHINE_IDENTITY_ID is required}"
  infisical login --method=oidc --oidc-client-id="${INFISICAL_MACHINE_IDENTITY_ID}" --domain="https://app.infisical.com"
}

setup_infisical() {
  setup_infisical_cli
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
  mkdir -p ~/.ssh
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  infisical ssh sign --public-key=~/.ssh/id_ed25519.pub --ca-id="${INFISICAL_SSH_CA_ID}" > ~/.ssh/id_ed25519-cert.pub
}

install_yq() {
  sudo wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq
  yq --version
}
