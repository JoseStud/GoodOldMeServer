# Spec Delta

## MODIFIED Requirements

### Requirement: Shadow Mode
`network_policy_sync.sh` and `network_policy_revoke_ssh.sh` SHALL parse `SHADOW_MODE` with `to_bool` (`true`, `1` or `yes`, case-insensitive) and, when true, MUST skip `sync_network_access_policy.sh`, append the policy as `network_access_policy_json` to `GITHUB_OUTPUT` when set, and exit 0; both still run `setup_infisical` first. Both are operator-run break-glass tools, and no orchestrator job SHALL invoke them.

#### Scenario: Shadow sync
- **WHEN** `network_policy_sync.sh` runs with `SHADOW_MODE=true`
- **THEN** it still builds and validates the policy, including the api.ipify.org lookup
- **AND** it prints "SHADOW_MODE=true: skipping sync_network_access_policy.sh mutation steps." and makes no Terraform Cloud write

#### Scenario: Shadow revoke
- **WHEN** `network_policy_revoke_ssh.sh` runs with `SHADOW_MODE=true`
- **THEN** it prints "SHADOW_MODE=true: skipping revoke of OCI SSH allow rules." and makes no Terraform Cloud write

#### Scenario: Operator break-glass dry run
- **WHEN** an operator runs `network_policy_sync.sh` locally with `BREAK_GLASS_POLICY_JSON` set to an enabled policy for one `/32` and `SHADOW_MODE=true`
- **THEN** the policy is validated and written to `GITHUB_OUTPUT` when set, and no Terraform Cloud write is made
- **AND** the same run without `SHADOW_MODE` writes the policy to the infra workspace variable, which opens SSH only after the operator queues and confirms an infra run

#### Scenario: Pipeline default
- **WHEN** an orchestrator run completes, whether the GitHub Actions variable `SHADOW_MODE` is unset, `false` or `true` and whatever its run toggles
- **THEN** neither script has run in any pipeline container
- **AND** the Terraform Cloud `network_access_policy` variable still holds the value the operator last wrote

## REMOVED Requirements

### Requirement: Runner SSH Policy Sync
**Reason**: The sync wrote the runner `/32` to Terraform Cloud only after the separate infra-apply job had finished, and it never started a run, so the value could not affect the apply that needed it. Automated SSH now goes over Tailscale only, so no runner address has to be allowed.
**Migration**: The pipeline needs nothing in its place. Before rollout the owner sets the infra workspace variable `network_access_policy` to `{"oci_ssh":{"enabled":false,"source_ranges":[]}}`. For break-glass public SSH, the operator runs `BREAK_GLASS_POLICY_JSON='{"oci_ssh":{"enabled":true,"source_ranges":["<operator IPv4>/32"]}}' bash .github/scripts/stages/network_policy_sync.sh` with Infisical and TFC credentials, or edits the variable in the Terraform Cloud UI, and then queues and confirms an infra run.

### Requirement: SSH Policy Revocation
**Reason**: The revoke stage was skipped whenever an earlier stage failed, which left a stale runner `/32` enabled for the next infra apply. With no automated stage enabling SSH, there is nothing for the pipeline to revoke.
**Migration**: At the end of a break-glass window the operator runs `bash .github/scripts/stages/network_policy_revoke_ssh.sh`, or sets the variable back to disabled in the Terraform Cloud UI, and then queues and confirms an infra run, which destroys the `gateway-nsg` TCP 22 rules.
