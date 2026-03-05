#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
: "${INVENTORY_FILE:?INVENTORY_FILE is required}"

SHADOW_MODE="$(to_bool "${SHADOW_MODE:-false}")"

checkout_stacks_sha "${STACKS_SHA:-}"
setup_infisical
generate_ephemeral_ssh_certificate

if [[ "${SHADOW_MODE}" == "true" ]]; then
  echo "SHADOW_MODE=true: skipping Ansible bootstrap mutation run."
  exit 0
fi

ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=accept-new -o CertificateFile=~/.ssh/id_ed25519-cert.pub -i ~/.ssh/id_ed25519' \
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod -- \
  ansible-playbook -i "${INVENTORY_FILE}" ansible/playbooks/provision.yml
