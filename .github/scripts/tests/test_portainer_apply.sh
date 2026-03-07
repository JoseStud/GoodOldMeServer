#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT_DIR}/.github/scripts/stages/portainer_apply.sh"

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
  local workdir="$2"
  local log_file="$3"
  shift 3
  local out_file="${TMP_DIR}/${case_name}.out"

  (
    set -euo pipefail
    cd "${workdir}"
    FAKE_TERRAFORM_LOG="${log_file}" "$@"
  ) >"${out_file}" 2>&1

  echo "${out_file}"
}

TEST_ROOT="${TMP_DIR}/repo"
BIN_DIR="${TMP_DIR}/bin"
mkdir -p \
  "${TEST_ROOT}/.github/scripts/stages" \
  "${TEST_ROOT}/.github/scripts/lib" \
  "${TEST_ROOT}/.github/scripts/tfc" \
  "${TEST_ROOT}/terraform/portainer-root" \
  "${BIN_DIR}"

cp "${SCRIPT}" "${TEST_ROOT}/.github/scripts/stages/portainer_apply.sh"

cat > "${TEST_ROOT}/.github/scripts/lib/workflow_common.sh" <<'EOF'
#!/usr/bin/env bash
to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    true|1|yes) echo "true" ;;
    *) echo "false" ;;
  esac
}
EOF
chmod +x "${TEST_ROOT}/.github/scripts/lib/workflow_common.sh"

cat > "${TEST_ROOT}/.github/scripts/tfc/assert_tfc_workspace_local_mode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${TEST_ROOT}/.github/scripts/tfc/assert_tfc_workspace_local_mode.sh"

cat > "${BIN_DIR}/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sha=%s cmd=%s\n' "${TF_VAR_stacks_sha:-__unset__}" "$*" >> "${FAKE_TERRAFORM_LOG}"
exit 0
EOF
chmod +x "${BIN_DIR}/terraform"

base_env=(
  env
  PATH="${BIN_DIR}:${PATH}"
  INFISICAL_TOKEN=test-token
  TFC_WORKSPACE_PORTAINER=test-portainer
  TFC_ORGANIZATION=test-org
  SHADOW_MODE=false
)

no_sha_log="${TMP_DIR}/no_sha.log"
touch "${no_sha_log}"
no_sha_out="$(run_case "without_stacks_sha" "${TEST_ROOT}" "${no_sha_log}" "${base_env[@]}" bash .github/scripts/stages/portainer_apply.sh)"
assert_contains "without_stacks_sha" "sha=__unset__ cmd=-chdir=terraform/portainer-root init -input=false -backend-config=organization=test-org -backend-config=workspaces.name=test-portainer" "${no_sha_log}"
assert_contains "without_stacks_sha" "sha=__unset__ cmd=-chdir=terraform/portainer-root plan -input=false -out=portainer.tfplan" "${no_sha_log}"
assert_contains "without_stacks_sha" "sha=__unset__ cmd=-chdir=terraform/portainer-root apply -input=false -auto-approve portainer.tfplan" "${no_sha_log}"
assert_not_contains "without_stacks_sha" "TF_VAR_stacks_sha" "${no_sha_out}"

with_sha_log="${TMP_DIR}/with_sha.log"
touch "${with_sha_log}"
with_sha="0123456789abcdef0123456789abcdef01234567"
run_case "with_stacks_sha" "${TEST_ROOT}" "${with_sha_log}" "${base_env[@]}" STACKS_SHA="${with_sha}" bash .github/scripts/stages/portainer_apply.sh >/dev/null
assert_contains "with_stacks_sha" "sha=${with_sha} cmd=-chdir=terraform/portainer-root init -input=false -backend-config=organization=test-org -backend-config=workspaces.name=test-portainer" "${with_sha_log}"
assert_contains "with_stacks_sha" "sha=${with_sha} cmd=-chdir=terraform/portainer-root plan -input=false -out=portainer.tfplan" "${with_sha_log}"
assert_contains "with_stacks_sha" "sha=${with_sha} cmd=-chdir=terraform/portainer-root apply -input=false -auto-approve portainer.tfplan" "${with_sha_log}"

echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
