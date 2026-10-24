# secrets-management Specification

## Purpose
Keep Infisical the single source of truth for homelab secrets. This capability covers:

- the project, environment and folder layout that Terraform, Ansible and the CI pipeline use
- how CI authenticates to Infisical, fetches secrets and passes them into containers
- the preflight secret validation that runs before stages
- the post-bootstrap Portainer secret check
- which secrets automation writes back
- how the vault is seeded

## Requirements

### Requirement: Infisical Project, Environment and Folder Layout
All automation SHALL use the Infisical project in `INFISICAL_PROJECT_ID` (Terraform: `var.infisical_project_id`) and the `prod` environment. Secrets live in `/infrastructure`, `/security`, `/cloud-provider/oci`, `/cloud-provider/gcp`, `/management`, `/deployments` and `/stacks/<name>` (`gateway`, `identity`, `management`, `network`, `observability`, `ai-interface`, `uptime`). CI scripts SHALL pass `--projectId` and `--env=prod` explicitly; the root `infisical.json` is `{}`.

#### Scenario: Stage script access
- **WHEN** a CI stage script reads or writes a secret
- **THEN** it invokes the `infisical` CLI with `--projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=<folder>`

#### Scenario: Missing project ID
- **WHEN** `INFISICAL_PROJECT_ID` is unset or empty for `secret_validation.sh`, `post_bootstrap_secret_check.sh`, `ansible_run.sh`, `health_gated_redeploy.sh` or `scripts/import_infisical_secrets.sh`
- **THEN** the script exits with `INFISICAL_PROJECT_ID is required` before contacting Infisical

#### Scenario: Host runtime sync inputs
- **WHEN** the `runtime_sync` Ansible role runs
- **THEN** it uses Infisical environment `prod` and domain `https://app.infisical.com`
- **AND** it takes `INFISICAL_PROJECT_ID`, `INFISICAL_AGENT_CLIENT_ID` and `INFISICAL_AGENT_CLIENT_SECRET` from the controller environment, failing its assertion if any of them is empty

### Requirement: CI Infisical Authentication Precedence
`setup_infisical` in `.github/scripts/lib/workflow_common.sh` SHALL require the `infisical` CLI. It SHALL obtain an access token using the first option that applies:

1. reuse `INFISICAL_TOKEN` when it is non-empty
2. Universal Auth when `INFISICAL_AGENT_CLIENT_ID` and `INFISICAL_AGENT_CLIENT_SECRET` are both non-empty
3. GitHub OIDC with `INFISICAL_MACHINE_IDENTITY_ID`

A newly obtained token SHALL be exported as `INFISICAL_TOKEN`.

#### Scenario: Token already present
- **WHEN** `INFISICAL_TOKEN` is non-empty
- **THEN** `setup_infisical` prints `INFISICAL_TOKEN is set; skipping OIDC login.` and sends no login request

#### Scenario: Universal Auth
- **WHEN** `INFISICAL_TOKEN` is empty and both agent client variables are set
- **THEN** it POSTs `clientId` and `clientSecret` to `${INFISICAL_DOMAIN:-https://app.infisical.com}/api/v1/auth/universal-auth/login` and uses the returned `accessToken`
- **AND** an empty or null `accessToken` fails with `Failed to obtain Infisical access token via Universal Auth.`

#### Scenario: GitHub OIDC fallback
- **WHEN** `INFISICAL_TOKEN` is empty and at least one agent client variable is empty
- **THEN** it fetches a GitHub OIDC JWT from `ACTIONS_ID_TOKEN_REQUEST_URL` using `ACTIONS_ID_TOKEN_REQUEST_TOKEN`, appending `&audience=<INFISICAL_OIDC_AUDIENCE>` when that variable is set
- **AND** it exchanges the JWT at `/api/v1/auth/oidc-auth/login` with `identityId` `INFISICAL_MACHINE_IDENTITY_ID`, failing if any of those inputs is missing or no `accessToken` is returned

### Requirement: Secret Retrieval Helper
`fetch_infisical_secret <path> <name>` SHALL print the value of the named secret by running `infisical run --projectId="${INFISICAL_PROJECT_ID}" --env=prod --path=<path>` around a shell that prints that variable. It SHALL print an empty string when the secret does not exist in that folder.

#### Scenario: Secret present
- **WHEN** the secret exists in the given folder
- **THEN** its value is written to stdout with no trailing newline

#### Scenario: Secret absent
- **WHEN** the secret does not exist in the given folder
- **THEN** the helper prints an empty string
- **AND** `validate_infisical_secret` reports `Missing required secret(s) in <path>: <name>` and returns 1

#### Scenario: Ansible playbook environment
- **WHEN** `ansible_run.sh` runs `ansible/playbooks/provision.yml`
- **THEN** it wraps `ansible-playbook` in nested `infisical run` invocations for `/infrastructure` and `/stacks/management`, so that the playbook sees secrets from both folders as environment variables

### Requirement: Dagger Container Credential Wiring
Dagger pipeline phases SHALL forward each Infisical credential from the runner environment only when it is non-empty. `INFISICAL_PROJECT_ID` and `INFISICAL_MACHINE_IDENTITY_ID` SHALL be passed as plain environment variables. `INFISICAL_TOKEN`, `INFISICAL_AGENT_CLIENT_ID`, `INFISICAL_AGENT_CLIENT_SECRET`, `ACTIONS_ID_TOKEN_REQUEST_TOKEN` and `ACTIONS_ID_TOKEN_REQUEST_URL` SHALL be passed as Dagger secret variables created with `client.set_secret`.

#### Scenario: Portainer-phase containers
- **WHEN** a stage container is built through `_wire_infisical` (post-bootstrap-secret-check, portainer-api-preflight, portainer-apply-debug, portainer-apply, or health-gated-redeploy)
- **THEN** `INFISICAL_OIDC_AUDIENCE` is also forwarded, as a plain environment variable

#### Scenario: Secret-validation container
- **WHEN** the secret-validation container is built
- **THEN** it receives `RUN_INFRA`, `RUN_ANSIBLE`, `RUN_PORTAINER`, `RUN_HOST_SYNC` and `RUN_HEALTH` as `true` or `false`, together with the credentials above
- **AND** `INFISICAL_OIDC_AUDIENCE` is not forwarded

#### Scenario: Orchestrator credential sources
- **WHEN** the `dagger-pipeline` job of `orchestrator.yml` runs
- **THEN** `INFISICAL_PROJECT_ID`, `INFISICAL_MACHINE_IDENTITY_ID` and `INFISICAL_OIDC_AUDIENCE` come from repository `vars.*`
- **AND** `INFISICAL_TOKEN`, `INFISICAL_AGENT_CLIENT_ID` and `INFISICAL_AGENT_CLIENT_SECRET` come from `secrets.*`, and the workflow grants `id-token: write`

### Requirement: Terraform Secret Consumption
Terraform SHALL read secrets through `infisical_secrets` data sources, configured with `env_slug = "prod"`, `workspace_id = var.infisical_project_id` and provider host `https://app.infisical.com`. Required keys SHALL be indexed directly, so a missing key fails the run. `DOCKER_SOCKET_PROXY_URL` (`/stacks/gateway`), `ARCH_PC_IP` (`/stacks/ai-interface`) and `PORTAINER_LICENSE_KEY` (`/management`) are read with `try(..., "")`, so a missing value becomes an empty string.

#### Scenario: Infra root
- **WHEN** `terraform/infra` plans
- **THEN** it reads `SSH_CA_PUBLIC_KEY` (`/security`), `OCI_COMPARTMENT_OCID` and `OCI_IMAGE_OCID` (`/cloud-provider/oci`), `GCP_PROJECT_ID` (`/cloud-provider/gcp`) and `TAILSCALE_AUTH_KEY` (`/infrastructure`)

#### Scenario: Portainer root
- **WHEN** `terraform/portainer-root` plans
- **THEN** it uses `PORTAINER_API_URL` (`/management`) as the Portainer provider endpoint and `PORTAINER_ADMIN_PASSWORD` (`/stacks/management`) as `api_password` for user `admin`
- **AND** the Dagger Terraform container sets `TF_VAR_infisical_project_id` from `INFISICAL_PROJECT_ID`

#### Scenario: Portainer stack environments
- **WHEN** the `terraform/portainer` module builds `portainer_stack_envs`
- **THEN** it reads `/infrastructure` and `/stacks/{gateway,identity,network,observability,ai-interface,uptime}`
- **AND** it requires `GF_DB_PASS`, `OPENWEBUI_DB_PASS`, `UPTIME_KUMA_DB_PASS`, `AUTHELIA_STORAGE_ENCRYPTION_KEY` and `AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET` among its directly indexed keys

### Requirement: Preflight Secret Validation Invocation
`preflight.secret_validation` SHALL run `.github/scripts/stages/secret_validation.sh` in an `infisical`-profile container, unless none of the infra, ansible, portainer, host-sync and health stages is enabled. The script SHALL require `INFISICAL_PROJECT_ID`, check stage-specific auth inputs, call `setup_infisical`, and exit non-zero at the first missing or invalid secret. A non-zero exit SHALL abort the pipeline.

#### Scenario: No stages enabled
- **WHEN** infra, ansible, portainer, host-sync and health are all disabled
- **THEN** the stage prints `secret-validation: skipped (no stages enabled)`

#### Scenario: Portainer auth input missing
- **WHEN** `RUN_PORTAINER=true` and both `INFISICAL_TOKEN` and `INFISICAL_MACHINE_IDENTITY_ID` are empty
- **THEN** the script prints `Missing required auth: either INFISICAL_TOKEN or INFISICAL_MACHINE_IDENTITY_ID (OIDC) must be set` and exits with status 1

#### Scenario: Agent credentials missing
- **WHEN** `RUN_ANSIBLE` or `RUN_HOST_SYNC` is `true` and `INFISICAL_AGENT_CLIENT_ID` or `INFISICAL_AGENT_CLIENT_SECRET` is empty
- **THEN** the script prints `Missing required secret: <name>` and exits with status 1 before reading any Infisical secret

### Requirement: Infrastructure and Bootstrap Secret Validation
`secret_validation.sh` SHALL apply the value check to these secrets, depending on the stage flags:

- `RUN_INFRA`: `/security` `SSH_CA_PUBLIC_KEY`, `/cloud-provider/oci` `OCI_COMPARTMENT_OCID` and `OCI_IMAGE_OCID`, and `/cloud-provider/gcp` `GCP_PROJECT_ID`
- `RUN_ANSIBLE`: `/infrastructure` `TAILSCALE_AUTH_KEY`, and `/stacks/management` `HOMARR_SECRET_KEY` and `PORTAINER_ADMIN_PASSWORD`
- `RUN_ANSIBLE` or `RUN_HOST_SYNC`: `/security` `SSH_CA_PRIVATE_KEY`

#### Scenario: Infra-only validation
- **WHEN** only `RUN_INFRA` is `true`
- **THEN** exactly `SSH_CA_PUBLIC_KEY`, `OCI_COMPARTMENT_OCID`, `OCI_IMAGE_OCID` and `GCP_PROJECT_ID` are validated

#### Scenario: Host sync without bootstrap
- **WHEN** `RUN_HOST_SYNC` is `true` and `RUN_ANSIBLE` is `false`
- **THEN** `SSH_CA_PRIVATE_KEY` is validated
- **AND** `TAILSCALE_AUTH_KEY`, `HOMARR_SECRET_KEY` and `PORTAINER_ADMIN_PASSWORD` are not

#### Scenario: Placeholder bootstrap secret
- **WHEN** `RUN_ANSIBLE` is `true` and `TAILSCALE_AUTH_KEY` is `your_tailscale_auth_key_here`
- **THEN** the script fails with `TAILSCALE_AUTH_KEY contains a placeholder value and must be replaced with a real secret.`

### Requirement: Portainer and Redeploy Secret Validation
When `RUN_ANSIBLE`, `RUN_PORTAINER` or `RUN_HEALTH` is `true`, `secret_validation.sh` SHALL validate the Portainer-managed stack secret set. `ALERTMANAGER_WEBHOOK_URL` gets the https check and every other secret in the set gets the value check. When `RUN_PORTAINER` is `true` and `RUN_ANSIBLE` is not, it SHALL also validate the `/management` credentials. When `RUN_HEALTH` is `true` and `RUN_PORTAINER` is not, it SHALL also validate the `/deployments` webhook URLs.

#### Scenario: Stack secret set contents
- **WHEN** the Portainer-managed stack secret set is validated
- **THEN** it checks `/infrastructure` `BASE_DOMAIN`, `TZ`, `CLOUDFLARE_API_TOKEN` and `ZONE_ID`, and `/stacks/gateway` `ACME_EMAIL` and `DOCKER_SOCKET_PROXY_URL`
- **AND** it checks `/stacks/identity` `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `POSTGRES_PASSWORD`, `AUTHELIA_NOTIFIER_SMTP_USERNAME`, `AUTHELIA_NOTIFIER_SMTP_PASSWORD`, `AUTHELIA_NOTIFIER_SMTP_SENDER`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET` and `AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY`
- **AND** it checks `/stacks/network` `VW_DB_PASS`, `VW_ADMIN_TOKEN` and `PIHOLE_PASSWORD`, `/stacks/observability` `GF_OIDC_CLIENT_ID`, `GF_OIDC_CLIENT_SECRET` and `ALERTMANAGER_WEBHOOK_URL`, and `/stacks/ai-interface` `ARCH_PC_IP`

#### Scenario: Portainer run without bootstrap
- **WHEN** `RUN_PORTAINER` is `true` and `RUN_ANSIBLE` is `false`
- **THEN** `/management` `PORTAINER_API_URL` and `PORTAINER_API_KEY` are validated with the value check, which does not enforce a URL scheme

#### Scenario: Health redeploy without Portainer apply
- **WHEN** `RUN_HEALTH` is `true` and `RUN_PORTAINER` is `false`
- **THEN** the following `/deployments` secrets are validated with the value check: `WEBHOOK_URL_GATEWAY`, `WEBHOOK_URL_AUTH`, `WEBHOOK_URL_NETWORK`, `WEBHOOK_URL_OBSERVABILITY`, `WEBHOOK_URL_AI_INTERFACE`, `WEBHOOK_URL_UPTIME` and `WEBHOOK_URL_CLOUD`

### Requirement: Secret Value Checks
The validation helpers in `workflow_common.sh` SHALL reject empty values and placeholder values (`is_placeholder_value`). The https check SHALL require a match for `^https://[^[:space:]]+$`. `assert_url_value` SHALL accept `http://` or `https://` URLs. `assert_bcrypt_hash_value` SHALL require a match for `^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$`. Both URL checks SHALL also reject placeholders, and an unsupported kind in `validate_infisical_secret` SHALL fail.

#### Scenario: Placeholder detection
- **WHEN** the lowercased value matches `your_*`, `*_here`, `changeme`, `change-me`, `change_me`, `replace-me`, `replace_me`, `placeholder`, `placeholder_*`, `dummy_*` or `test_*`, or contains `placeholder`, `example.com`, `example.org` or `example.net`
- **THEN** it is rejected with `<NAME> contains a placeholder value and must be replaced with a real secret.`

#### Scenario: Non-https webhook URL
- **WHEN** `ALERTMANAGER_WEBHOOK_URL` does not start with `https://`
- **THEN** validation fails with `ALERTMANAGER_WEBHOOK_URL must be a valid https URL.`
- **AND** an https URL under `example.com` fails with the placeholder-URL message

#### Scenario: Invalid bcrypt hash
- **WHEN** `PORTAINER_ADMIN_PASSWORD_HASH` is not a `$2a$`, `$2b$` or `$2y$` hash with a two-digit cost and 53 trailing characters
- **THEN** validation fails with `PORTAINER_ADMIN_PASSWORD_HASH must be a valid bcrypt hash.`

### Requirement: Post-Bootstrap Portainer Secret Check
When `RUN_PORTAINER_APPLY` is `true`, the pipeline SHALL run `post_bootstrap_secret_check.sh` after the Ansible layer and before `portainer-api-preflight`. The script SHALL check `/management` `PORTAINER_API_URL` (http/https URL) and `PORTAINER_API_KEY` (non-placeholder), and `/stacks/management` `PORTAINER_ADMIN_PASSWORD` (non-placeholder) and `PORTAINER_ADMIN_PASSWORD_HASH` (bcrypt). It SHALL then probe `GET <url>/system/status` with `X-API-Key` and a 10-second timeout.

#### Scenario: Valid API key
- **WHEN** the status probe returns HTTP 200
- **THEN** the script prints `Portainer API key secret is valid.` and exits with status 0 without writing to Infisical

#### Scenario: Unexpected probe result
- **WHEN** the probe returns a code other than 200, 401 or 403, including `000` on a connection failure
- **THEN** the script prints `Portainer API key validation failed unexpectedly (HTTP <code>).` and exits with status 1 without rotating the key

#### Scenario: Secret format failure
- **WHEN** `PORTAINER_ADMIN_PASSWORD_HASH` fails the bcrypt check, or another fetched secret fails its check
- **THEN** the script exits non-zero before contacting Portainer

### Requirement: Stale Portainer API Key Rotation
When the status probe returns 401 or 403, `post_bootstrap_secret_check.sh` SHALL rotate the key in these steps:

1. authenticate at `<url>/auth` as `PORTAINER_ADMIN_USER` (default `admin`) with `PORTAINER_ADMIN_PASSWORD`
2. delete every `/users/1/tokens` entry whose description is `terraform-managed`
3. create a new `terraform-managed` token
4. write its `rawAPIKey` to `/management` `PORTAINER_API_KEY` with `infisical secrets set --env=prod`
5. re-probe `/system/status` with the new key

#### Scenario: Successful rotation
- **WHEN** the probe returns 401 or 403 and every rotation step succeeds
- **THEN** the new key is stored in Infisical `/management` `PORTAINER_API_KEY`
- **AND** the script prints `Portainer API key rotated and written back to Infisical.` and exits with status 0

#### Scenario: Admin authentication fails
- **WHEN** the `/auth` response contains no `jwt`
- **THEN** the script prints `Failed to authenticate to Portainer API for token rotation.` and exits with status 1

#### Scenario: Rotated key rejected
- **WHEN** the new key has been written to Infisical but the re-probe does not return 200
- **THEN** the script prints `Rotated Portainer API key failed validation (HTTP <code>).` and exits with status 1

### Requirement: Automation-Managed Secrets
These secrets SHALL be written by automation rather than by operators:

- by the `portainer_bootstrap` Ansible role: `/stacks/management` `PORTAINER_ADMIN_PASSWORD_HASH`, and `/management` `PORTAINER_URL`, `PORTAINER_API_URL` and `PORTAINER_API_KEY`
- by `post_bootstrap_secret_check.sh` when it rotates the key: `PORTAINER_API_KEY`
- by the `terraform/portainer` module: `/deployments` `WEBHOOK_URL_*` and `PORTAINER_WEBHOOK_URLS`

#### Scenario: Bootstrap write-back
- **WHEN** `portainer_bootstrap` runs with a non-empty `INFISICAL_PROJECT_ID`
- **THEN** it runs `infisical secrets set ... --env=prod` on the controller (`delegate_to: localhost`, `run_once`) for `PORTAINER_ADMIN_PASSWORD_HASH` and `PORTAINER_API_KEY`
- **AND** it writes `PORTAINER_URL=https://portainer.<BASE_DOMAIN>` unless the base domain is `localhost`, and `PORTAINER_API_URL=http://<ts_ip>:9000/api` only when `ts_ip` is defined

#### Scenario: Terraform webhook outputs
- **WHEN** the `terraform/portainer` module applies
- **THEN** each `portainer_stack.swarm` gets an `infisical_secret` in `/deployments`, environment `prod`
- **AND** the secret is named `WEBHOOK_URL_<NAME>`: the stack name uppercased with `-` replaced by `_` (for example `WEBHOOK_URL_AI_INTERFACE`), and its value is the stack's `webhook_url`
- **AND** `PORTAINER_WEBHOOK_URLS` holds all the webhook URLs joined by commas

#### Scenario: Seed script skips managed keys
- **WHEN** `scripts/import_infisical_secrets.sh` runs
- **THEN** it sets none of `PORTAINER_URL`, `PORTAINER_API_URL`, `PORTAINER_API_KEY`, `PORTAINER_ADMIN_PASSWORD_HASH` or the `/deployments` webhook secrets
- **AND** it prints a `Skipping automation-managed ...` line for each of these groups

### Requirement: Infisical Seed Script
`scripts/import_infisical_secrets.sh` SHALL require `INFISICAL_PROJECT_ID` and rely on an existing Infisical CLI login. For each seeded key it SHALL call `infisical secrets set KEY=VALUE --env=prod --projectId=<id> --path=<folder>` with a fixed placeholder or default value. It SHALL ignore the result of each call (`|| true`) and SHALL NOT read the stored values first.

#### Scenario: Project ID missing
- **WHEN** `INFISICAL_PROJECT_ID` is unset or empty
- **THEN** the script exits with `INFISICAL_PROJECT_ID is required` before calling `infisical`

#### Scenario: Failed set call
- **WHEN** an `infisical secrets set` call fails
- **THEN** the script continues with the remaining keys and still exits with status 0

#### Scenario: Seeding existing keys
- **WHEN** a seeded key already holds a value in Infisical
- **THEN** the script still issues `infisical secrets set` with its seed value, for example `BASE_DOMAIN=example.com`, `CLOUDFLARE_API_TOKEN=your_cloudflare_api_token_here` or `PORTAINER_LICENSE_KEY=` (empty)
- **AND** most seed values match the placeholder patterns that preflight validation rejects
