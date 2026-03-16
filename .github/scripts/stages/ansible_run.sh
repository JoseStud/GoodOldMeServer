#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
: "${INVENTORY_FILE:?INVENTORY_FILE is required}"

ANSIBLE_TAGS="${ANSIBLE_TAGS:-}"

checkout_stacks_sha "${STACKS_SHA:-}"
setup_infisical
generate_ephemeral_ssh_certificate

ansible-galaxy collection install -r ansible/requirements.yml

exit_if_shadow_mode "SHADOW_MODE=true: skipping Ansible mutation run."

ansible_args=(-i "${INVENTORY_FILE}" ansible/playbooks/provision.yml)
if [[ -n "${ANSIBLE_TAGS}" ]]; then
  ansible_args+=(--tags "${ANSIBLE_TAGS}")
fi

ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-30}" \
ANSIBLE_ROLES_PATH=ansible/roles \
ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=accept-new -o CertificateFile=~/.ssh/id_ed25519-cert.pub -i ~/.ssh/id_ed25519' \
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod -- \
  ansible-playbook "${ansible_args[@]}"
