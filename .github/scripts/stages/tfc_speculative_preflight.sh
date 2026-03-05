#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${WORKSPACE_KEY:?WORKSPACE_KEY is required}"
: "${TFC_TOKEN:?Missing required secret: TFC_TOKEN}"
: "${TFC_ORGANIZATION:?Missing required variable: TFC_ORGANIZATION (or fallback TFC_ORG).}"

workspace_name=""
case "${WORKSPACE_KEY}" in
  infra)
    workspace_name="${TFC_WORKSPACE_INFRA:-}"
    ;;
  portainer)
    workspace_name="${TFC_WORKSPACE_PORTAINER:-}"
    ;;
  *)
    echo "Unknown workspace key: ${WORKSPACE_KEY}"
    exit 1
    ;;
esac

if [[ -z "${workspace_name}" ]]; then
  echo "Missing required workspace variable for '${WORKSPACE_KEY}'."
  exit 1
fi

echo "workspace_name=${workspace_name}" >> "${GITHUB_OUTPUT}"
