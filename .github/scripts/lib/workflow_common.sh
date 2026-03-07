#!/usr/bin/env bash

set -euo pipefail

PLAN_SCHEMA_VERSION="ci-plan-v1"

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

emit_output() {
  local key="$1"
  local value="$2"
  echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
}

normalize_nullable() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo ""
    return
  fi
  echo "${value}"
}

normalize_csv() {
  local input="${1:-}"
  input="$(echo "${input}" | tr -d '\r')"
  if [[ -z "${input}" || "${input}" == "null" ]]; then
    echo ""
    return
  fi

  IFS=',' read -ra parts <<< "${input}"
  if [[ ${#parts[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  printf '%s\n' "${parts[@]}" \
    | awk '{$1=$1; print}' \
    | awk 'NF > 0' \
    | awk '!seen[$0]++' \
    | sort \
    | paste -sd, -
}

normalize_json_array_to_csv() {
  local input="${1:-}"
  local item_regex="${2:-.*}"
  local field_name="${3:-json_array}"

  if [[ -z "${input}" || "${input}" == "null" ]]; then
    echo ""
    return
  fi

  if ! jq -e --arg re "${item_regex}" '
      type == "array"
      and all(.[]; type == "string" and test($re))
    ' <<<"${input}" >/dev/null; then
    echo "Invalid ${field_name}: expected JSON array of strings matching regex '${item_regex}'."
    exit 1
  fi

  jq -r '.[]' <<<"${input}" \
    | awk '{$1=$1; print}' \
    | awk 'NF > 0' \
    | awk '!seen[$0]++' \
    | sort \
    | paste -sd, -
}

append_unique() {
  local value="$1"
  shift
  local -a current=("$@")
  local existing=""
  for existing in "${current[@]}"; do
    if [[ "${existing}" == "${value}" ]]; then
      return 1
    fi
  done
  return 0
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command not found: ${cmd}"
    exit 1
  fi
}

is_placeholder_value() {
  local normalized="${1:-}"
  normalized="${normalized,,}"

  if [[ -z "${normalized}" ]]; then
    return 1
  fi

  case "${normalized}" in
    your_*|*_here|changeme|change-me|change_me|replace-me|replace_me|placeholder|placeholder_*|dummy_*|test_*)
      return 0
      ;;
  esac

  [[ "${normalized}" == *"placeholder"* ]]
}

is_placeholder_url_value() {
  local normalized="${1:-}"
  normalized="${normalized,,}"

  if is_placeholder_value "${normalized}"; then
    return 0
  fi

  [[ "${normalized}" == *"example.com"* || "${normalized}" == *"example.org"* || "${normalized}" == *"example.net"* ]]
}

assert_nonempty_value() {
  local name="$1"
  local value="${2:-}"

  if [[ -z "${value}" ]]; then
    echo "Missing required secret: ${name}" >&2
    return 1
  fi
}

assert_nonplaceholder_value() {
  local name="$1"
  local value="${2:-}"

  assert_nonempty_value "${name}" "${value}" || return 1

  if is_placeholder_value "${value}"; then
    echo "${name} contains a placeholder value and must be replaced with a real secret." >&2
    return 1
  fi
}

assert_https_url_value() {
  local name="$1"
  local value="${2:-}"

  assert_nonempty_value "${name}" "${value}" || return 1

  if [[ ! "${value}" =~ ^https://[^[:space:]]+$ ]]; then
    echo "${name} must be a valid https URL." >&2
    return 1
  fi

  if is_placeholder_url_value "${value}"; then
    echo "${name} contains a placeholder URL and must be replaced with a real endpoint." >&2
    return 1
  fi
}

assert_bcrypt_hash_value() {
  local name="$1"
  local value="${2:-}"

  assert_nonempty_value "${name}" "${value}" || return 1

  if [[ ! "${value}" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]; then
    echo "${name} must be a valid bcrypt hash." >&2
    return 1
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

fetch_infisical_secret() {
  local path="$1"
  local secret_name="$2"

  SECRET_NAME="${secret_name}" \
    infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path="${path}" -- \
      bash -lc 'printf %s "${!SECRET_NAME:-}"'
}

require_infisical_secrets() {
  local path="$1"
  shift

  local required_csv
  if [[ $# -eq 0 ]]; then
    return 0
  fi

  required_csv="$(IFS=,; printf '%s' "$*")"

  REQUIRED_VARS="${required_csv}" \
  INFISICAL_PATH="${path}" \
    infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path="${path}" -- \
      bash -lc '
        missing=()
        IFS="," read -r -a required_vars <<< "${REQUIRED_VARS}"
        for name in "${required_vars[@]}"; do
          if [[ -z "${!name:-}" ]]; then
            missing+=("${name}")
          fi
        done

        if ((${#missing[@]} > 0)); then
          IFS=,
          printf "Missing required secret(s) in %s: %s\n" "${INFISICAL_PATH}" "${missing[*]}" >&2
          exit 1
        fi
      '
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
