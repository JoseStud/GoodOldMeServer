#!/usr/bin/env bash

set -euo pipefail

bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

require_value() {
  local name="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    echo "Missing required value: ${name}"
    exit 1
  fi
}

resolve_value() {
  local override="$1"
  local lock_value="$2"
  if [[ -n "${override}" ]]; then
    echo "${override}"
  else
    echo "${lock_value}"
  fi
}

write_output() {
  local key="$1"
  local value="$2"
  echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
}

download_file() {
  local label="$1"
  local url="$2"
  local dest="$3"

  if ! curl -fsSL "${url}" -o "${dest}"; then
    echo "Failed to download ${label} from ${url}"
    exit 1
  fi
}

verify_sha256() {
  local label="$1"
  local expected="$2"
  local file="$3"
  local actual

  actual="$(sha256sum "${file}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "${label} checksum mismatch"
    echo "Expected: ${expected}"
    echo "Actual:   ${actual}"
    echo "Source:   ${file}"
    exit 1
  fi
}

LOCK_PATH="${INPUT_TOOL_VERSIONS_LOCK_PATH:-.github/ci/tool-versions.lock}"
if [[ ! -f "${LOCK_PATH}" ]]; then
  echo "Lock file not found: ${LOCK_PATH}"
  exit 1
fi

# shellcheck disable=SC1090
source "${LOCK_PATH}"

INSTALL_JQ="$(bool "${INPUT_INSTALL_JQ:-false}")"
INSTALL_YQ="$(bool "${INPUT_INSTALL_YQ:-false}")"

install_jq() {
  local version sha url tmp
  version="$(resolve_value "${INPUT_JQ_VERSION:-}" "${JQ_VERSION:-}")"
  sha="$(resolve_value "${INPUT_JQ_SHA256:-}" "${JQ_SHA256:-}")"
  require_value "jq_version" "${version}"
  require_value "jq_sha256" "${sha}"

  url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-linux-amd64"
  tmp="$(mktemp)"

  download_file "jq ${version}" "${url}" "${tmp}"
  verify_sha256 "jq ${version}" "${sha}" "${tmp}"
  sudo install -m 0755 "${tmp}" /usr/local/bin/jq
  rm -f "${tmp}"

  write_output "jq_version_installed" "$(jq --version | sed 's/^jq-//')"
}

install_yq() {
  local version sha url tmp
  version="$(resolve_value "${INPUT_YQ_VERSION:-}" "${YQ_VERSION:-}")"
  sha="$(resolve_value "${INPUT_YQ_SHA256:-}" "${YQ_SHA256:-}")"
  require_value "yq_version" "${version}"
  require_value "yq_sha256" "${sha}"

  url="https://github.com/mikefarah/yq/releases/download/v${version}/yq_linux_amd64"
  tmp="$(mktemp)"

  download_file "yq ${version}" "${url}" "${tmp}"
  verify_sha256 "yq ${version}" "${sha}" "${tmp}"
  sudo install -m 0755 "${tmp}" /usr/local/bin/yq
  rm -f "${tmp}"

  write_output "yq_version_installed" "$(yq --version | awk '{print $NF}' | sed 's/^v//')"
}

write_output "jq_version_installed" ""
write_output "yq_version_installed" ""

if [[ "${INSTALL_JQ}" == "true" ]]; then
  install_jq
fi

if [[ "${INSTALL_YQ}" == "true" ]]; then
  install_yq
fi
