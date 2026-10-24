# Spec Delta

## MODIFIED Requirements

### Requirement: Stage Layering
`ci_pipeline` SHALL run enabled stages in this order: stacks-sha-trust and secret-validation concurrently; then cloudflare-dns-sync; then the Ansible bootstrap or host-sync subprocess; then post-bootstrap-secret-check, config-sync, portainer-api-preflight, portainer-apply-debug, portainer-apply and health-gated-redeploy, one at a time. It SHALL NOT run any stage that writes the Terraform Cloud `network_access_policy` variable.

#### Scenario: Full-run push
- **WHEN** `RUN_INFRA_APPLY`, `RUN_ANSIBLE_BOOTSTRAP` and `RUN_PORTAINER_APPLY` are `true` and the other toggles are `false`
- **THEN** the stages run as stacks-sha-trust with secret-validation, cloudflare-dns-sync, Ansible bootstrap, post-bootstrap-secret-check, portainer-api-preflight, portainer-apply-debug, portainer-apply
- **AND** the pipeline logs `pipeline: complete` without having written the Terraform Cloud `network_access_policy` variable

#### Scenario: Stacks SHA bump
- **WHEN** `RUN_PORTAINER_APPLY`, `RUN_HOST_SYNC`, `RUN_CONFIG_SYNC` and `RUN_HEALTH_REDEPLOY` are `true` and `RUN_INFRA_APPLY` and `RUN_ANSIBLE_BOOTSTRAP` are `false`
- **THEN** cloudflare-dns-sync runs alone in its layer, followed by host-sync, post-bootstrap-secret-check, config-sync, portainer-api-preflight, portainer-apply-debug, portainer-apply and health-gated-redeploy
- **AND** no `network-policy-sync` or `network-policy-revoke-ssh` log line is printed

#### Scenario: Network policy handover to the Portainer preflight
- **WHEN** portainer-api-preflight runs
- **THEN** it receives `NETWORK_ACCESS_POLICY_JSON` set to `{"oci_ssh":{"enabled":false,"source_ranges":[]}}`, whatever the run toggles
- **AND** no earlier stage produces a policy value for it, because no network-policy-sync stage exists

### Requirement: Stage Run Conditions
Each stage SHALL run only under its gate: stacks-sha-trust when `STACKS_SHA` is non-empty; secret-validation when any run toggle other than `RUN_CONFIG_SYNC` is set; cloudflare-dns-sync always; post-bootstrap-secret-check, portainer-apply-debug and portainer-apply on `RUN_PORTAINER_APPLY`; portainer-api-preflight on that or `RUN_HEALTH_REDEPLOY`; health-gated-redeploy on `RUN_HEALTH_REDEPLOY`. `RUN_INFRA_APPLY` and `RUN_ANSIBLE_BOOTSTRAP` SHALL NOT start any network-policy stage.

#### Scenario: Toggle parsing
- **WHEN** a `RUN_*` or `HAS_WORK` variable is unset, or holds anything other than `true` in any letter case
- **THEN** the pipeline treats it as false

#### Scenario: Narrow Portainer retry
- **WHEN** a dispatch with `ansible_only=true` and `skip_ansible_bootstrap=true` gives `RUN_PORTAINER_APPLY=true` and every other toggle `false`
- **THEN** no inventory is rendered and Ansible and health-gated-redeploy do not run
- **AND** stacks-sha-trust, secret-validation, cloudflare-dns-sync, post-bootstrap-secret-check, portainer-api-preflight, portainer-apply-debug and portainer-apply run

#### Scenario: Infra apply or bootstrap run
- **WHEN** `RUN_INFRA_APPLY` or `RUN_ANSIBLE_BOOTSTRAP` is `true`
- **THEN** no stage looks up the runner's public IPv4 for an SSH policy or writes the Terraform Cloud `network_access_policy` variable

#### Scenario: Skipped preflight logging
- **WHEN** `STACKS_SHA` is empty, or none of the toggles that secret-validation checks is set
- **THEN** the pipeline logs `stacks-sha-trust: skipped (no stacks_sha)` or `secret-validation: skipped (no stages enabled)` and continues
