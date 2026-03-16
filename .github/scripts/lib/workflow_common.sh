#!/usr/bin/env bash

set -euo pipefail

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}

# Boolean predicate (exit code) — use in conditionals.
# to_bool() returns a string for assignment; this returns 0/1 for `if`.
is_true() {
  case "${1,,}" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# 40-character lowercase hex SHA — used by dispatch validation, stacks trust, plan resolution.
SHA_REGEX='^[0-9a-f]{40}$'

is_valid_sha() {
  local sha="${1:-}"
  [[ "${sha}" =~ ${SHA_REGEX} ]]
}

emit_output() {
  local key="$1"
  local value="$2"
  if [[ "${value}" == *$'\n'* ]]; then
    # Multiline: use heredoc delimiter form (GitHub Actions requirement).
    local delimiter="EOF_${RANDOM}_${RANDOM}"
    {
      printf '%s<<%s\n' "${key}" "${delimiter}"
      printf '%s\n' "${value}"
      printf '%s\n' "${delimiter}"
    } >> "${GITHUB_OUTPUT}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${GITHUB_OUTPUT}"
  fi
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

csv_contains() {
  local item="$1" csv="$2"
  local trimmed_item="${item#"${item%%[![:space:]]*}"}"
  trimmed_item="${trimmed_item%"${trimmed_item##*[![:space:]]}"}"
  local IFS=","
  local part
  for part in ${csv}; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ "${part}" == "${trimmed_item}" ]] && return 0
  done
  return 1
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

  [[ "${normalized}" == *"placeholder"* \
    || "${normalized}" == *"example.com"* \
    || "${normalized}" == *"example.org"* \
    || "${normalized}" == *"example.net"* ]]
}

is_placeholder_url_value() {
  local normalized="${1:-}"
  normalized="${normalized,,}"

  is_placeholder_value "${normalized}"
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

exit_if_shadow_mode() {
  local message="${1:-SHADOW_MODE=true: skipping mutation.}"
  if [[ "$(to_bool "${SHADOW_MODE:-false}")" == "true" ]]; then
    echo "${message}"
    exit 0
  fi
}

infisical_oidc_login() {
  : "${INFISICAL_MACHINE_IDENTITY_ID:?INFISICAL_MACHINE_IDENTITY_ID is required}"
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?ACTIONS_ID_TOKEN_REQUEST_URL is required (needs id-token: write permission)}"
  : "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?ACTIONS_ID_TOKEN_REQUEST_TOKEN is required}"

  local oidc_url="${ACTIONS_ID_TOKEN_REQUEST_URL}"
  if [[ -n "${INFISICAL_OIDC_AUDIENCE:-}" ]]; then
    oidc_url="${oidc_url}&audience=${INFISICAL_OIDC_AUDIENCE}"
  fi

  local oidc_jwt
  oidc_jwt="$(curl -sSfL \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${oidc_url}" \
    | jq -r '.value')"

  if [[ -z "${oidc_jwt}" || "${oidc_jwt}" == "null" ]]; then
    echo "Failed to obtain GitHub OIDC JWT for Infisical login."
    exit 1
  fi

  infisical login --method=oidc-auth --machine-identity-id="${INFISICAL_MACHINE_IDENTITY_ID}" --jwt="${oidc_jwt}" --domain="${INFISICAL_DOMAIN:-https://app.infisical.com}"
}

setup_infisical() {
  require_command infisical
  if [[ -n "${INFISICAL_TOKEN:-}" ]]; then
    echo "INFISICAL_TOKEN is set; skipping OIDC login."
    return
  fi
  infisical_oidc_login
}

fetch_infisical_secret() {
  local path="$1"
  local secret_name="$2"

  SECRET_NAME="${secret_name}" \
    infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path="${path}" -- \
      bash -lc 'printf %s "${!SECRET_NAME:-}"'
}

validate_infisical_secret() {
  local path="$1"
  local secret_name="$2"
  local kind="${3:-value}"
  local secret_value

  secret_value="$(fetch_infisical_secret "${path}" "${secret_name}")"
  if [[ -z "${secret_value}" ]]; then
    echo "Missing required secret(s) in ${path}: ${secret_name}" >&2
    return 1
  fi

  case "${kind}" in
    value)
      assert_nonplaceholder_value "${secret_name}" "${secret_value}"
      ;;
    https_url)
      assert_https_url_value "${secret_name}" "${secret_value}"
      ;;
    *)
      echo "Unsupported secret validation kind: ${kind}" >&2
      return 1
      ;;
  esac
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
