# Spec Delta

## MODIFIED Requirements

### Requirement: Infrastructure and Bootstrap Secret Validation
`secret_validation.sh` SHALL apply the value check to these secrets, depending on the stage flags:

- `RUN_INFRA`: `/security` `SSH_CA_PUBLIC_KEY`, `/cloud-provider/oci` `OCI_COMPARTMENT_OCID` and `OCI_IMAGE_OCID`, and `/cloud-provider/gcp` `GCP_PROJECT_ID`
- `RUN_ANSIBLE`: `/infrastructure` `TAILSCALE_AUTH_KEY`, and `/stacks/management` `HOMARR_SECRET_KEY`, `HOMARR_DB_PASS` and `PORTAINER_ADMIN_PASSWORD`
- `RUN_ANSIBLE` or `RUN_HOST_SYNC`: `/security` `SSH_CA_PRIVATE_KEY`

#### Scenario: Infra-only validation
- **WHEN** only `RUN_INFRA` is `true`
- **THEN** exactly `SSH_CA_PUBLIC_KEY`, `OCI_COMPARTMENT_OCID`, `OCI_IMAGE_OCID` and `GCP_PROJECT_ID` are validated

#### Scenario: Host sync without bootstrap
- **WHEN** `RUN_HOST_SYNC` is `true` and `RUN_ANSIBLE` is `false`
- **THEN** `SSH_CA_PRIVATE_KEY` is validated
- **AND** `TAILSCALE_AUTH_KEY`, `HOMARR_SECRET_KEY`, `HOMARR_DB_PASS` and `PORTAINER_ADMIN_PASSWORD` are not

#### Scenario: Placeholder bootstrap secret
- **WHEN** `RUN_ANSIBLE` is `true` and `TAILSCALE_AUTH_KEY` is `your_tailscale_auth_key_here`
- **THEN** the script fails with `TAILSCALE_AUTH_KEY contains a placeholder value and must be replaced with a real secret.`

#### Scenario: Homarr database password missing
- **WHEN** `RUN_ANSIBLE` is `true` and `/stacks/management` `HOMARR_DB_PASS` is absent, empty or a placeholder
- **THEN** the value check fails for `HOMARR_DB_PASS` and the script exits non-zero during the preflight layer, before the Ansible stage runs

### Requirement: Automation-Managed Secrets
These secrets SHALL be written by automation rather than by operators:

- by the `portainer_bootstrap` Ansible role: `/stacks/management` `PORTAINER_ADMIN_PASSWORD_HASH` (when it generates a new hash), and `/management` `PORTAINER_URL`, `PORTAINER_API_URL` and `PORTAINER_API_KEY`
- by `post_bootstrap_secret_check.sh` when it rotates the key: `PORTAINER_API_KEY`
- by the `terraform/portainer` module: `/deployments` `WEBHOOK_URL_*` and `PORTAINER_WEBHOOK_URLS`

#### Scenario: Bootstrap write-back
- **WHEN** `portainer_bootstrap` runs with a non-empty `INFISICAL_PROJECT_ID`
- **THEN** it runs `infisical secrets set ... --env=prod` on the controller (`delegate_to: localhost`, `run_once`) for `PORTAINER_API_KEY`, and for `PORTAINER_ADMIN_PASSWORD_HASH` only when it had to generate a new hash
- **AND** it writes `PORTAINER_URL=https://portainer.<BASE_DOMAIN>` unless the base domain is `localhost`, and `PORTAINER_API_URL=http://<ts_ip>:9000/api` only when `ts_ip` is defined

#### Scenario: Stored admin hash still valid
- **WHEN** `portainer_bootstrap` runs and the `PORTAINER_ADMIN_PASSWORD_HASH` injected from `/stacks/management` verifies against `PORTAINER_ADMIN_PASSWORD`
- **THEN** `/stacks/management` `PORTAINER_ADMIN_PASSWORD_HASH` is not rewritten, so its value and version in Infisical stay unchanged

#### Scenario: Terraform webhook outputs
- **WHEN** the `terraform/portainer` module applies
- **THEN** each `portainer_stack.swarm` gets an `infisical_secret` in `/deployments`, environment `prod`
- **AND** the secret is named `WEBHOOK_URL_<NAME>`: the stack name uppercased with `-` replaced by `_` (for example `WEBHOOK_URL_AI_INTERFACE`), and its value is the stack's `webhook_url`
- **AND** `PORTAINER_WEBHOOK_URLS` holds all the webhook URLs joined by commas

#### Scenario: Seed script skips managed keys
- **WHEN** `scripts/import_infisical_secrets.sh` runs
- **THEN** it sets none of `PORTAINER_URL`, `PORTAINER_API_URL`, `PORTAINER_API_KEY`, `PORTAINER_ADMIN_PASSWORD_HASH` or the `/deployments` webhook secrets
- **AND** it prints a `Skipping automation-managed ...` line for each of these groups
