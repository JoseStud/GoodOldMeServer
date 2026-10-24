# network-access-policy Specification

## Purpose
Define the canonical `network_access_policy` that gates public IPv4 SSH to the OCI workers, and the CI scripts that build it from the runner's egress IP or a break-glass override, validate it, sync it to the Terraform Cloud infra workspace, revoke it, and check it in the network preflight.

## Requirements

### Requirement: Network Access Policy Variable
The infra root SHALL declare variable `network_access_policy` of type `object({ oci_ssh = object({ enabled = bool, source_ranges = list(string) }) })` with no default, and its validation MUST reject any source range that is not a valid CIDR or that contains `:`, and MUST reject `enabled = true` with an empty `source_ranges` list.

#### Scenario: Valid enabled policy
- **WHEN** the variable is `{"oci_ssh":{"enabled":true,"source_ranges":["203.0.113.10/32"]}}`
- **THEN** validation passes and module `oci` receives `ssh_enabled = true` and `ssh_allowed_cidrs = ["203.0.113.10/32"]`
- **AND** the policy is not passed to module `gcp`

#### Scenario: IPv6 or empty-while-enabled ranges
- **WHEN** `source_ranges` contains an IPv6 CIDR, or `enabled` is true and `source_ranges` is empty
- **THEN** validation fails with "network_access_policy is invalid: oci_ssh.source_ranges must contain only valid IPv4 CIDRs."

#### Scenario: Disabled policy
- **WHEN** the variable is `{"oci_ssh":{"enabled":false,"source_ranges":[]}}`
- **THEN** validation passes and no OCI SSH NSG rule is planned

### Requirement: Policy Source Selection
`.github/scripts/network/build_network_access_policy.sh` SHALL use the file at `BREAK_GLASS_POLICY_FILE` when that variable is set, otherwise `BREAK_GLASS_POLICY_JSON` when set, otherwise build `{"oci_ssh":{"enabled":true,"source_ranges":["<runner IPv4>/32"]}}` from `https://api.ipify.org` fetched with `curl -4 -fsS --retry 3 --retry-delay 1 --max-time 10`.

#### Scenario: Runner IPv4 policy
- **WHEN** neither break-glass variable is set and api.ipify.org returns the runner's public IPv4
- **THEN** the policy enables OCI SSH for exactly that address as a `/32`

#### Scenario: Break-glass file precedence
- **WHEN** both `BREAK_GLASS_POLICY_FILE` and `BREAK_GLASS_POLICY_JSON` are set
- **THEN** the file content is used and "Using break-glass policy file: <path>" is printed

#### Scenario: Missing break-glass file or IP lookup failure
- **WHEN** `BREAK_GLASS_POLICY_FILE` names a file that does not exist, or the api.ipify.org request fails after retries
- **THEN** the script exits non-zero, printing "Break-glass policy file not found: <path>" in the missing-file case

### Requirement: Policy Validation and Canonical Output
`build_network_access_policy.sh` MUST require `jq`, MUST fail unless the policy is an object whose `oci_ssh` is an object with boolean `enabled` and array `source_ranges`, MUST fail when any range is not an IPv4 network per Python `ipaddress.ip_network(strict=False)` or the list is empty while enabled, and SHALL emit the policy as compact key-sorted JSON.

#### Scenario: Valid policy output
- **WHEN** the policy passes validation
- **THEN** the compact key-sorted JSON is printed as the last stdout line
- **AND** when `GITHUB_OUTPUT` is set, `network_access_policy_json=<json>` and `oci_ssh_source_ranges=<comma-joined ranges>` are appended to it

#### Scenario: IPv6 range rejected
- **WHEN** `oci_ssh.source_ranges` contains an IPv6 CIDR
- **THEN** the script fails with "oci_ssh.source_ranges must contain only IPv4 CIDRs: '<range>'"

#### Scenario: Empty ranges allowed only when disabled
- **WHEN** `oci_ssh.enabled` is false and `source_ranges` is empty
- **THEN** validation passes
- **AND** the same empty list with `enabled` true fails with "oci_ssh.source_ranges must not be empty"

### Requirement: Terraform Cloud Policy Variable Upsert
`.github/scripts/network/sync_network_access_policy.sh` SHALL require `NETWORK_ACCESS_POLICY_JSON`, `TFC_TOKEN`, `TFC_ORGANIZATION`, `TFC_WORKSPACE_INFRA` and `INFISICAL_PROJECT_ID`, resolve the workspace ID from `TFC_API_URL` (default `https://app.terraform.io/api/v2`), and write the canonical policy JSON to variable `TFC_POLICY_VAR_KEY` (default `network_access_policy`) with category `terraform`, `hcl` true and `sensitive` false.

#### Scenario: Existing terraform-category variable
- **WHEN** the workspace already has a terraform-category variable with the policy key
- **THEN** the script PATCHes `/vars/<id>` with the new value and description "Managed by infrastructure orchestrator network policy sync"

#### Scenario: Variable absent
- **WHEN** no terraform-category variable with the policy key exists
- **THEN** the script POSTs the variable to `/workspaces/<workspace id>/vars`

#### Scenario: API failure
- **WHEN** the workspace cannot be resolved, or the write response contains `"errors"`
- **THEN** the script exits non-zero, printing "Failed to PATCH TFC variable (id=<id>)." or "Failed to create TFC variable 'network_access_policy'." for write failures

### Requirement: Legacy Policy Variable Removal
When the infra workspace has an env-category variable `TF_VAR_network_access_policy`, `sync_network_access_policy.sh` SHALL delete it after writing the terraform-category variable, and a failed deletion MUST only print a warning without failing the sync.

#### Scenario: Legacy env variable present
- **WHEN** the variable listing contains `TF_VAR_network_access_policy` with category `env`
- **THEN** the script sends DELETE `/vars/<id>` for it after the upsert

#### Scenario: Legacy deletion fails
- **WHEN** the DELETE response contains `"errors"`
- **THEN** the script prints "Warning: failed to delete legacy TFC variable (id=<id>). Continuing." and proceeds to verification

### Requirement: Read-After-Write Verification
After writing, `sync_network_access_policy.sh` SHALL re-list the workspace variables (`page[size]=200`), read the terraform-category policy value, and MUST fail unless its compact key-sorted JSON equals the canonical input; on success it SHALL append `network_access_policy_json` to `GITHUB_OUTPUT` when set.

#### Scenario: Value verified
- **WHEN** the read-back value matches the input policy
- **THEN** the script prints "Network access policy sync completed and verified." and exits 0

#### Scenario: Value mismatch
- **WHEN** the read-back value differs from the input policy
- **THEN** the script prints "Terraform Cloud variable verification failed." with the expected and actual JSON and exits 1

#### Scenario: Value missing
- **WHEN** no terraform-category value is found on read-back
- **THEN** the script prints "Failed to read back network_access_policy from Terraform Cloud." and exits 1

### Requirement: Shadow Mode
`network_policy_sync.sh` and `network_policy_revoke_ssh.sh` SHALL parse `SHADOW_MODE` with `to_bool` (`true`, `1` or `yes`, case-insensitive) and, when true, MUST skip `sync_network_access_policy.sh`, append the policy as `network_access_policy_json` to `GITHUB_OUTPUT` when set, and exit 0; both still run `setup_infisical` first.

#### Scenario: Shadow sync
- **WHEN** `network_policy_sync.sh` runs with `SHADOW_MODE=true`
- **THEN** it still builds and validates the policy, including the api.ipify.org lookup
- **AND** it prints "SHADOW_MODE=true: skipping sync_network_access_policy.sh mutation steps." and makes no Terraform Cloud write

#### Scenario: Shadow revoke
- **WHEN** `network_policy_revoke_ssh.sh` runs with `SHADOW_MODE=true`
- **THEN** it prints "SHADOW_MODE=true: skipping revoke of OCI SSH allow rules." and makes no Terraform Cloud write

#### Scenario: Pipeline default
- **WHEN** the GitHub Actions variable `SHADOW_MODE` is unset for the orchestrator
- **THEN** the dagger-pipeline job passes `SHADOW_MODE=false` into the network containers

### Requirement: Runner SSH Policy Sync
In the Dagger pipeline, network-policy-sync SHALL run only when `RUN_INFRA_APPLY` or `RUN_ANSIBLE_BOOTSTRAP` is true, after the separate infra-apply job has finished and the stacks-sha-trust and secret-validation preflights, alongside Cloudflare DNS sync; it SHALL only write the TFC variable and MUST NOT start a Terraform Cloud run, so the value takes effect on the next infra apply.

#### Scenario: Infra apply enabled
- **WHEN** a workflow run has `run_infra_apply` true
- **THEN** the dagger-pipeline job starts only after the infra-apply job succeeded, so that apply used the variable value present before this sync
- **AND** `network_policy_sync.sh` writes the runner `/32` policy to the infra workspace variable without creating a run

#### Scenario: No infra apply or bootstrap
- **WHEN** both `RUN_INFRA_APPLY` and `RUN_ANSIBLE_BOOTSTRAP` are false
- **THEN** the pipeline prints "network-policy-sync: skipped (tailscale-first run, no infra/bootstrap SSH policy mutation)"
- **AND** later stages receive the policy `{"oci_ssh":{"enabled":false,"source_ranges":[]}}`

#### Scenario: Policy handed to later stages
- **WHEN** the sync stage completes in the Dagger `network` container
- **THEN** the last `network_access_policy_json` line it wrote to its output file becomes the policy passed to portainer-api-preflight
- **AND** `BREAK_GLASS_POLICY_JSON` and `BREAK_GLASS_POLICY_FILE` are not passed into that container, so the runner IPv4 path is used

### Requirement: SSH Policy Revocation
When `RUN_INFRA_APPLY` or `RUN_ANSIBLE_BOOTSTRAP` is true, the Dagger pipeline SHALL run `network_policy_revoke_ssh.sh` as its final stage, writing `{"oci_ssh":{"enabled":false,"source_ranges":[]}}` to the TFC infra workspace variable via `sync_network_access_policy.sh` without starting a run; it SHALL run only if every earlier stage succeeded and MUST NOT run after an earlier stage fails.

#### Scenario: Successful pipeline
- **WHEN** every earlier stage succeeds
- **THEN** the revoke stage writes and verifies the disabled policy and prints "OCI SSH allow rules revoked (network_access_policy.oci_ssh.enabled=false)."
- **AND** no Terraform Cloud run is created, so OCI SSH NSG rules change only on the next infra apply

#### Scenario: Earlier stage fails
- **WHEN** an earlier Dagger stage raises an exec error or the host Ansible run exits non-zero
- **THEN** the pipeline exits non-zero without running the revoke stage
- **AND** the TFC variable keeps the value written by network-policy-sync, since the orchestrator defines no always-run revoke job

#### Scenario: Policy management not enabled
- **WHEN** both `RUN_INFRA_APPLY` and `RUN_ANSIBLE_BOOTSTRAP` are false
- **THEN** the pipeline prints "network-policy-revoke-ssh: skipped (no SSH policy sync was applied)"

### Requirement: Network Preflight Policy Check
`.github/scripts/network/preflight_network_access.sh` MUST require `NETWORK_ACCESS_POLICY_JSON`; when `RUN_ANSIBLE`, `RUN_HOST_SYNC` or `RUN_CONFIG` is true it SHALL read `ansible_host` values from `INVENTORY_FILE` (default `inventory-ci.yml`), and if any is an IPv4 literal MUST fail unless `oci_ssh.enabled` is true and the runner IPv4 from api.ipify.org is in `oci_ssh.source_ranges`, then check TCP 22 on each host with `nc -z -w5`.

#### Scenario: SSH disabled while IPv4 hosts are targeted
- **WHEN** SSH checks are requested, the inventory has an IPv4 `ansible_host`, and `oci_ssh.enabled` is false
- **THEN** the script fails with "network_access_policy.oci_ssh.enabled is false but the current run requires IPv4 SSH access."

#### Scenario: Runner outside the allowed ranges
- **WHEN** SSH checks are requested for an IPv4 host and the runner IPv4 is not in `oci_ssh.source_ranges`
- **THEN** the script fails with "Runner IPv4 egress is not in network_access_policy.oci_ssh.source_ranges."

#### Scenario: Hostname inventory entries
- **WHEN** an `ansible_host` is not an IPv4 literal
- **THEN** when the `tailscale` CLI is available the script tries `tailscale ip -4` for it (also `app-worker-N` for `oci-node-N`), polling every `TAILSCALE_PEER_POLL_INTERVAL` (default 15) seconds for up to `TAILSCALE_PEER_WAIT_SECONDS` (default 300), and otherwise keeps the hostname
- **AND** when no IPv4 literal host exists, the runner IP is not looked up and the policy is not checked

### Requirement: Portainer API Preflight Invocation
When `RUN_PORTAINER_APPLY` or `RUN_HEALTH_REDEPLOY` is true, the pipeline SHALL run `portainer_api_preflight.sh`, which reads `PORTAINER_API_URL` from Infisical `/management` and calls `preflight_network_access.sh` with `RUN_ANSIBLE=false` and `RUN_CONFIG=false`, so no SSH or runner-IP checks run; the preflight MUST then get HTTP 200 or 401 from `<url>/api/system/status` within 10 seconds.

#### Scenario: Portainer reachable
- **WHEN** `<PORTAINER_API_URL without trailing / or /api>/api/system/status` returns 200 or 401
- **THEN** the preflight prints "Portainer API preflight passed (HTTP <code>)."
- **AND** the policy JSON it receives (the sync output, or the disabled default) is only parsed, never compared with the runner IP

#### Scenario: Portainer unreachable or unexpected status
- **WHEN** the status endpoint returns any other code or the request fails
- **THEN** the preflight fails with "Portainer API preflight failed (expected 200 or 401, got <code>)."

#### Scenario: Missing Portainer URL
- **WHEN** `PORTAINER_API_URL` is empty in Infisical `/management`
- **THEN** `portainer_api_preflight.sh` prints "PORTAINER_API_URL is missing in Infisical /management." and exits 1
