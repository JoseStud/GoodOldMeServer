#!/usr/bin/env bash

set -euo pipefail

source .github/scripts/lib/workflow_common.sh

: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"

RUN_INFRA="${RUN_INFRA:-false}"
RUN_ANSIBLE="${RUN_ANSIBLE:-false}"
RUN_PORTAINER="${RUN_PORTAINER:-false}"
RUN_HEALTH="${RUN_HEALTH:-false}"

setup_infisical

if [[ "${RUN_INFRA}" == "true" ]]; then
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/security -- bash -lc '[[ -n "${SSH_CA_PUBLIC_KEY:-}" ]]'
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/cloud-provider/oci -- bash -lc '[[ -n "${OCI_COMPARTMENT_OCID:-}" && -n "${OCI_IMAGE_OCID:-}" ]]'
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/cloud-provider/gcp -- bash -lc '[[ -n "${GCP_PROJECT_ID:-}" ]]'
fi

if [[ "${RUN_ANSIBLE}" == "true" ]]; then
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/infrastructure -- bash -lc '[[ -n "${BASE_DOMAIN:-}" && -n "${TZ:-}" && -n "${TAILSCALE_AUTH_KEY:-}" ]]'
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/stacks/management -- bash -lc '[[ -n "${HOMARR_SECRET_KEY:-}" && -n "${PORTAINER_ADMIN_PASSWORD:-}" && -n "${PORTAINER_AUTOMATION_ALLOWED_CIDRS:-}" ]]'
fi

if [[ "${RUN_PORTAINER}" == "true" && "${RUN_ANSIBLE}" != "true" ]]; then
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/management -- bash -lc '[[ -n "${PORTAINER_API_URL:-}" && -n "${PORTAINER_API_KEY:-}" ]]'
fi

if [[ "${RUN_HEALTH}" == "true" ]]; then
  if [[ "${RUN_PORTAINER}" != "true" ]]; then
    infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/deployments -- bash -lc '[[ -n "${PORTAINER_WEBHOOK_URLS:-}" ]]'
  fi
  infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=/infrastructure -- bash -lc '[[ -n "${BASE_DOMAIN:-}" ]]'
fi
