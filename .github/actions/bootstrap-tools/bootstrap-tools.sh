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

LOCK_PATH="${INPUT_TOOL_VERSIONS_LOCK_PATH:-.github/ci/tool-versions.lock}"
if [[ ! -f "${LOCK_PATH}" ]]; then
  echo "Lock file not found: ${LOCK_PATH}"
  exit 1
fi

# shellcheck disable=SC1090
source "${LOCK_PATH}"

INSTALL_JQ="$(bool "${INPUT_INSTALL_JQ:-false}")"
INSTALL_YQ="$(bool "${INPUT_INSTALL_YQ:-false}")"
INSTALL_NETCAT="$(bool "${INPUT_INSTALL_NETCAT:-false}")"
INSTALL_INFISICAL="$(bool "${INPUT_INSTALL_INFISICAL:-false}")"
INFISICAL_LOGIN="$(bool "${INPUT_INFISICAL_LOGIN:-false}")"

apt_updated="false"
ensure_apt_updated() {
  if [[ "${apt_updated}" == "false" ]]; then
    sudo apt-get update
    apt_updated="true"
  fi
}

install_jq() {
  local version sha url tmp
  version="$(resolve_value "${INPUT_JQ_VERSION:-}" "${JQ_VERSION:-}")"
  sha="$(resolve_value "${INPUT_JQ_SHA256:-}" "${JQ_SHA256:-}")"
  require_value "jq_version" "${version}"
  require_value "jq_sha256" "${sha}"

  url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-linux-amd64"
  tmp="$(mktemp)"

  curl -fsSL "${url}" -o "${tmp}"
  echo "${sha}  ${tmp}" | sha256sum -c -
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

  curl -fsSL "${url}" -o "${tmp}"
  echo "${sha}  ${tmp}" | sha256sum -c -
  sudo install -m 0755 "${tmp}" /usr/local/bin/yq
  rm -f "${tmp}"

  write_output "yq_version_installed" "$(yq --version | awk '{print $NF}' | sed 's/^v//')"
}

install_netcat() {
  local version sha deb_file
  version="$(resolve_value "${INPUT_NETCAT_DEB_VERSION:-}" "${NETCAT_DEB_VERSION:-}")"
  sha="$(resolve_value "${INPUT_NETCAT_DEB_SHA256:-}" "${NETCAT_DEB_SHA256:-}")"
  require_value "netcat_deb_version" "${version}"
  require_value "netcat_deb_sha256" "${sha}"

  ensure_apt_updated
  apt-get download "netcat-openbsd=${version}"
  deb_file="$(ls -1 netcat-openbsd_*_amd64.deb | head -n1)"
  require_value "netcat-openbsd deb artifact" "${deb_file}"

  echo "${sha}  ${deb_file}" | sha256sum -c -
  sudo apt-get install -y "./${deb_file}"
  rm -f "${deb_file}"

  write_output "nc_version_installed" "$(dpkg-query -W -f='${Version}' netcat-openbsd)"
}

setup_infisical_repo() {
  if [[ -f /etc/apt/sources.list.d/infisical-core.list ]]; then
    return
  fi

  sudo mkdir -p /usr/share/keyrings
  curl -1sLf "https://dl.cloudsmith.io/public/infisical/infisical-core/gpg.2BA6932366A755776.gpg" \
    | sudo gpg --dearmor -o /usr/share/keyrings/infisical-core-archive-keyring.gpg

  printf "deb [signed-by=/usr/share/keyrings/infisical-core-archive-keyring.gpg] https://dl.cloudsmith.io/public/infisical/infisical-core/deb/debian any-version main\n" \
    | sudo tee /etc/apt/sources.list.d/infisical-core.list >/dev/null
}

install_infisical() {
  local version sha deb_file
  version="$(resolve_value "${INPUT_INFISICAL_VERSION:-}" "${INFISICAL_VERSION:-}")"
  sha="$(resolve_value "${INPUT_INFISICAL_SHA256:-}" "${INFISICAL_SHA256:-}")"
  require_value "infisical_version" "${version}"
  require_value "infisical_sha256" "${sha}"

  setup_infisical_repo
  apt_updated="false"
  ensure_apt_updated

  apt-get download "infisical-core=${version}"
  deb_file="$(ls -1 infisical-core_*_amd64.deb | head -n1)"
  require_value "infisical-core deb artifact" "${deb_file}"

  echo "${sha}  ${deb_file}" | sha256sum -c -
  sudo apt-get install -y "./${deb_file}"
  rm -f "${deb_file}"

  write_output "infisical_version_installed" "$(dpkg-query -W -f='${Version}' infisical-core)"
}

run_infisical_login() {
  local machine_id domain
  machine_id="${INPUT_INFISICAL_MACHINE_IDENTITY_ID:-}"
  domain="${INPUT_INFISICAL_DOMAIN:-https://app.infisical.com}"
  require_value "infisical_machine_identity_id" "${machine_id}"

  infisical login --method=oidc --oidc-client-id="${machine_id}" --domain="${domain}"
}

write_output "jq_version_installed" ""
write_output "yq_version_installed" ""
write_output "nc_version_installed" ""
write_output "infisical_version_installed" ""

if [[ "${INSTALL_JQ}" == "true" ]]; then
  install_jq
fi

if [[ "${INSTALL_YQ}" == "true" ]]; then
  install_yq
fi

if [[ "${INSTALL_NETCAT}" == "true" ]]; then
  install_netcat
fi

if [[ "${INSTALL_INFISICAL}" == "true" ]]; then
  install_infisical
fi

if [[ "${INFISICAL_LOGIN}" == "true" ]]; then
  if [[ "${INSTALL_INFISICAL}" != "true" ]] && ! command -v infisical >/dev/null 2>&1; then
    echo "infisical_login=true requires install_infisical=true or an existing infisical CLI in PATH."
    exit 1
  fi
  run_infisical_login
fi
