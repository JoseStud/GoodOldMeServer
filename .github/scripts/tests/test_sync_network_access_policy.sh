#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/network/sync_network_access_policy.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  local message="$1"
  echo "[PASS] ${message}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local message="$1"
  echo "[FAIL] ${message}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
  local case_name="$1"
  local pattern="$2"
  local file="$3"

  if grep -Fq -- "${pattern}" "${file}"; then
    pass "${case_name}: found '${pattern}'"
  else
    fail "${case_name}: missing '${pattern}'"
  fi
}

assert_not_contains() {
  local case_name="$1"
  local pattern="$2"
  local file="$3"

  if grep -Fq -- "${pattern}" "${file}"; then
    fail "${case_name}: unexpected '${pattern}'"
  else
    pass "${case_name}: absent '${pattern}'"
  fi
}

run_case() {
  local case_name="$1"
  shift
  local out_file="${TMP_DIR}/${case_name}.out"

  (
    set -euo pipefail
    "$@"
  ) >"${out_file}" 2>&1

  echo "${out_file}"
}

run_case_expect_fail() {
  local case_name="$1"
  shift
  local out_file="${TMP_DIR}/${case_name}.out"

  if (
    set -euo pipefail
    "$@"
  ) >"${out_file}" 2>&1; then
    fail "${case_name}: expected failure but script succeeded" >&2
  else
    pass "${case_name}: failed as expected" >&2
  fi

  echo "${out_file}"
}

BIN_DIR="${TMP_DIR}/bin"
FAKE_INFISICAL_ROOT="${TMP_DIR}/infisical"
FAKE_TFC_ROOT="${TMP_DIR}/tfc"
mkdir -p "${BIN_DIR}" "${FAKE_INFISICAL_ROOT}" "${FAKE_TFC_ROOT}"

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
payload=""
url=""

printf '%s\n' "$*" >> "${FAKE_CURL_LOG}"

while (($# > 0)); do
  case "$1" in
    -sSfL)
      shift
      ;;
    -X)
      method="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    -d)
      payload="$2"
      shift 2
      ;;
    -*)
      echo "Unexpected curl option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "${url}" ]]; then
        echo "Unexpected extra curl argument: $1" >&2
        exit 1
      fi
      url="$1"
      shift
      ;;
  esac
done

if [[ -z "${url}" ]]; then
  echo "Missing curl URL" >&2
  exit 1
fi

case "${method}:${url}" in
  GET:https://app.terraform.io/api/v2/organizations/test-org/workspaces/test-workspace)
    printf '%s\n' '{"data":{"id":"ws-123"}}'
    ;;
  GET:https://app.terraform.io/api/v2/workspaces/ws-123/vars\?page\[size\]=200)
    if [[ -f "${FAKE_TFC_ROOT}/policy-value" ]]; then
      value="$(cat "${FAKE_TFC_ROOT}/policy-value")"
      jq -cn --arg value "${value}" '{
        data: [
          {
            id: "var-123",
            attributes: {
              key: "TF_VAR_network_access_policy",
              category: "env",
              value: $value
            }
          }
        ]
      }'
    else
      printf '%s\n' '{"data":[]}'
    fi
    ;;
  POST:https://app.terraform.io/api/v2/workspaces/ws-123/vars|PATCH:https://app.terraform.io/api/v2/vars/var-123)
    saved_value="$(jq -r '.data.attributes.value' <<<"${payload}")"
    if [[ -n "${FAKE_TFC_MUTATE_VALUE:-}" ]]; then
      saved_value="${FAKE_TFC_MUTATE_VALUE}"
    fi
    printf '%s' "${saved_value}" > "${FAKE_TFC_ROOT}/policy-value"
    printf '%s\n' '{"data":{"id":"var-123"}}'
    ;;
  *)
    echo "Unexpected curl invocation: ${method} ${url}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BIN_DIR}/curl"

cat > "${BIN_DIR}/infisical" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_INFISICAL_LOG}"

command_name="${1:-}"
if [[ -z "${command_name}" ]]; then
  echo "Missing infisical command" >&2
  exit 1
fi
shift

case "${command_name}" in
  secrets)
    subcommand="${1:-}"
    shift
    if [[ "${subcommand}" != "set" ]]; then
      echo "Unsupported infisical secrets subcommand: ${subcommand}" >&2
      exit 1
    fi

    secret_assignment=""
    project_id="implicit-project"
    path=""

    while (($# > 0)); do
      case "$1" in
        --projectId=*)
          project_id="${1#*=}"
          shift
          ;;
        --projectId)
          project_id="$2"
          shift 2
          ;;
        --env=*|--env)
          shift
          if [[ "${1:-}" != --* && "${1:-}" != "" ]]; then
            shift
          fi
          ;;
        --path=*)
          path="${1#*=}"
          shift
          ;;
        --path)
          path="$2"
          shift 2
          ;;
        *=*)
          secret_assignment="$1"
          shift
          ;;
        *)
          echo "Unexpected infisical secrets set arg: $1" >&2
          exit 1
          ;;
      esac
    done

    if [[ "${FAKE_INFISICAL_SKIP_WRITE:-false}" != "true" ]]; then
      target_dir="${FAKE_INFISICAL_ROOT}/${project_id}${path}"
      mkdir -p "${target_dir}"
      printf '%s\n' "${secret_assignment}" > "${target_dir}/env"
    fi
    ;;
  run)
    project_id="implicit-project"
    path=""

    while (($# > 0)); do
      case "$1" in
        --projectId=*)
          project_id="${1#*=}"
          shift
          ;;
        --projectId)
          project_id="$2"
          shift 2
          ;;
        --env=*|--env)
          shift
          if [[ "${1:-}" != --* && "${1:-}" != "" ]]; then
            shift
          fi
          ;;
        --path=*)
          path="${1#*=}"
          shift
          ;;
        --path)
          path="$2"
          shift 2
          ;;
        --)
          shift
          break
          ;;
        *)
          echo "Unexpected infisical run arg: $1" >&2
          exit 1
          ;;
      esac
    done

    env_file="${FAKE_INFISICAL_ROOT}/${project_id}${path}/env"
    if [[ -f "${env_file}" ]]; then
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        export "${line}"
      done < "${env_file}"
    fi

    if [[ -n "${FAKE_INFISICAL_OVERRIDE_CIDRS:-}" ]]; then
      export PORTAINER_AUTOMATION_ALLOWED_CIDRS="${FAKE_INFISICAL_OVERRIDE_CIDRS}"
    fi

    exec "$@"
    ;;
  *)
    echo "Unsupported infisical command: ${command_name}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BIN_DIR}/infisical"

policy_json='{"oci_ssh":{"enabled":true,"source_ranges":["203.0.113.10/32"]},"gcp_ssh":{"enabled":true,"source_ranges":["2001:db8::10/128"]},"portainer_api":{"source_ranges":["203.0.113.10/32","2001:db8::10/128"]}}'
portainer_cidrs='203.0.113.10/32,2001:db8::10/128'

success_curl_log="${TMP_DIR}/success-curl.log"
success_infisical_log="${TMP_DIR}/success-infisical.log"
touch "${success_curl_log}" "${success_infisical_log}"
success_out="$(run_case "sync_success" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_CURL_LOG="${success_curl_log}" \
  FAKE_INFISICAL_LOG="${success_infisical_log}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  FAKE_TFC_ROOT="${FAKE_TFC_ROOT}" \
  NETWORK_ACCESS_POLICY_JSON="${policy_json}" \
  TFC_TOKEN=test-token \
  TFC_ORGANIZATION=test-org \
  TFC_WORKSPACE_INFRA=test-workspace \
  INFISICAL_PROJECT_ID=test-project \
  bash "${SCRIPT}")"
assert_contains "sync_success" "Network access policy sync completed and verified." "${success_out}"
assert_contains "sync_success" "secrets set PORTAINER_AUTOMATION_ALLOWED_CIDRS=${portainer_cidrs} --projectId=test-project --env=prod --path=/stacks/management" "${success_infisical_log}"
assert_contains "sync_success" "run --projectId=test-project --env=prod --path=/stacks/management -- bash -lc" "${success_infisical_log}"

rm -f "${FAKE_TFC_ROOT}/policy-value"
terraform_mismatch_curl_log="${TMP_DIR}/terraform-mismatch-curl.log"
terraform_mismatch_infisical_log="${TMP_DIR}/terraform-mismatch-infisical.log"
touch "${terraform_mismatch_curl_log}" "${terraform_mismatch_infisical_log}"
terraform_mismatch_out="$(run_case_expect_fail "terraform_verification_mismatch" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_CURL_LOG="${terraform_mismatch_curl_log}" \
  FAKE_INFISICAL_LOG="${terraform_mismatch_infisical_log}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  FAKE_TFC_ROOT="${FAKE_TFC_ROOT}" \
  FAKE_TFC_MUTATE_VALUE='{"oci_ssh":{"enabled":false,"source_ranges":[]},"gcp_ssh":{"enabled":true,"source_ranges":["2001:db8::10/128"]},"portainer_api":{"source_ranges":["203.0.113.10/32","2001:db8::10/128"]}}' \
  NETWORK_ACCESS_POLICY_JSON="${policy_json}" \
  TFC_TOKEN=test-token \
  TFC_ORGANIZATION=test-org \
  TFC_WORKSPACE_INFRA=test-workspace \
  INFISICAL_PROJECT_ID=test-project \
  bash "${SCRIPT}")"
assert_contains "terraform_verification_mismatch" "Terraform Cloud variable verification failed." "${terraform_mismatch_out}"
assert_not_contains "terraform_verification_mismatch" "secrets set PORTAINER_AUTOMATION_ALLOWED_CIDRS=" "${terraform_mismatch_infisical_log}"

rm -f "${FAKE_TFC_ROOT}/policy-value"
infisical_mismatch_curl_log="${TMP_DIR}/infisical-mismatch-curl.log"
infisical_mismatch_infisical_log="${TMP_DIR}/infisical-mismatch-infisical.log"
touch "${infisical_mismatch_curl_log}" "${infisical_mismatch_infisical_log}"
infisical_mismatch_out="$(run_case_expect_fail "infisical_verification_mismatch" env \
  PATH="${BIN_DIR}:${PATH}" \
  FAKE_CURL_LOG="${infisical_mismatch_curl_log}" \
  FAKE_INFISICAL_LOG="${infisical_mismatch_infisical_log}" \
  FAKE_INFISICAL_ROOT="${FAKE_INFISICAL_ROOT}" \
  FAKE_TFC_ROOT="${FAKE_TFC_ROOT}" \
  FAKE_INFISICAL_OVERRIDE_CIDRS="127.0.0.1/32" \
  NETWORK_ACCESS_POLICY_JSON="${policy_json}" \
  TFC_TOKEN=test-token \
  TFC_ORGANIZATION=test-org \
  TFC_WORKSPACE_INFRA=test-workspace \
  INFISICAL_PROJECT_ID=test-project \
  bash "${SCRIPT}")"
assert_contains "infisical_verification_mismatch" "Infisical secret verification failed." "${infisical_mismatch_out}"
assert_contains "infisical_verification_mismatch" "secrets set PORTAINER_AUTOMATION_ALLOWED_CIDRS=${portainer_cidrs} --projectId=test-project --env=prod --path=/stacks/management" "${infisical_mismatch_infisical_log}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
