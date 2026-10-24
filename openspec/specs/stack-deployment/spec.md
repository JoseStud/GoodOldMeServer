# stack-deployment Specification

## Purpose
Converge the Portainer-managed Docker Swarm stacks declared in the stacks repository manifest (stacks.yaml): Terraform in terraform/portainer-root and terraform/portainer creates Git-backed swarm stacks with webhooks and publishes the webhook URLs to Infisical, and the CI pipeline applies that Terraform and performs a health-gated, dependency-ordered webhook redeploy.

## Requirements

### Requirement: Stacks Manifest Contract
The Portainer module and the health-gated redeploy SHALL consume a stacks.yaml whose `stacks` map is keyed by stack name, each entry carrying `compose_path`, `portainer_managed`, `depends_on` and optionally `healthcheck_url`, `healthcheck_expected_status` and `healthcheck_timeout_seconds`. Only entries with `portainer_managed: true` SHALL be treated as Portainer-managed; an entry without the key SHALL be treated as not managed.

#### Scenario: Ansible-owned stack is excluded
- **WHEN** stacks.yaml declares `management` with `portainer_managed: false` and gateway, auth, network, observability, ai-interface, home-dashboard, uptime and cloud with `portainer_managed: true`
- **THEN** Terraform manages a Portainer stack only for the eight managed entries
- **AND** the health-gated redeploy triggers webhooks only for those eight stacks

#### Scenario: Entry without portainer_managed
- **WHEN** a manifest entry omits `portainer_managed`
- **THEN** Terraform (`try(cfg.portainer_managed, false)`) and the redeploy script (`select(.value.portainer_managed == true)`) both skip that entry

### Requirement: Portainer Root Configuration
terraform/portainer-root SHALL declare an empty `remote` backend configured at init time and SHALL configure the Portainer provider with endpoint `/management` PORTAINER_API_URL, `api_user = "admin"` and `api_password` from `/stacks/management` PORTAINER_ADMIN_PASSWORD (Infisical env `prod`, host `https://app.infisical.com`). It SHALL pass `/management` PORTAINER_LICENSE_KEY, or an empty string when absent, to the module as `license_key`.

#### Scenario: License key present
- **WHEN** `/management` contains a non-empty PORTAINER_LICENSE_KEY
- **THEN** the module manages one `portainer_licenses.be` resource with that key and `force = true`

#### Scenario: License key absent
- **WHEN** PORTAINER_LICENSE_KEY is not present in `/management`
- **THEN** `license_key` is empty and no `portainer_licenses` resource is created

#### Scenario: Root defaults and outputs
- **WHEN** the root is applied without overriding variables other than the required `infisical_project_id`
- **THEN** it uses `portainer_endpoint_id = 1`, `repository_url = https://github.com/JoseStud/stacks.git` and `repository_reference = refs/heads/main`
- **AND** it exposes `portainer_webhook_urls` (sensitive map of stack name to webhook URL) and `portainer_stack_ids` (map of stack name to Portainer stack ID)

### Requirement: Manifest Source Resolution
The module SHALL fetch the manifest with the `http` data source from an effective URL: when `stacks_sha` is set and `repository_url` has the form `https://github.com/<owner>/<repo>[.git]` or `git@github.com:<owner>/<repo>[.git]`, it SHALL use `https://raw.githubusercontent.com/<owner>/<repo>/<stacks_sha>/stacks.yaml`; otherwise it SHALL use `stacks_manifest_url`. `stacks_sha` MUST be null or a 40-character lowercase hex SHA.

#### Scenario: Pinned manifest from stacks_sha
- **WHEN** `stacks_sha` is a valid commit SHA and `repository_url` is `https://github.com/JoseStud/stacks.git`
- **THEN** the manifest is fetched from `https://raw.githubusercontent.com/JoseStud/stacks/<stacks_sha>/stacks.yaml`

#### Scenario: No stacks_sha
- **WHEN** `stacks_sha` is null
- **THEN** the manifest is fetched from `stacks_manifest_url`, default `https://raw.githubusercontent.com/JoseStud/stacks/main/stacks.yaml`

#### Scenario: stacks_sha with a non-GitHub repository URL
- **WHEN** `stacks_sha` is set but `repository_url` does not parse as a GitHub owner/repo URL
- **THEN** the manifest is fetched from `stacks_manifest_url` and the `stacks_sha_requires_github_repository_url` check reports a warning

#### Scenario: Private manifest token and invalid SHA
- **WHEN** `stacks_manifest_token` is non-null and non-blank
- **THEN** the request carries `Authorization: Bearer <token>`
- **AND** a `stacks_sha` that is not 40 lowercase hex characters fails variable validation

### Requirement: Stack Source Repository Reference
Every Portainer stack SHALL be created from `repository_url` at `repository_reference` (default `refs/heads/main`) with `file_path_in_repository` set to the manifest `compose_path`. `stacks_sha` SHALL only change which stacks.yaml is fetched, so webhook redeploys pull the compose files at the configured reference, not at `stacks_sha`.

#### Scenario: CI apply with a trusted stacks SHA
- **WHEN** the pipeline runs portainer-apply with STACKS_SHA set and no `TF_VAR_repository_reference`
- **THEN** the stack list comes from stacks.yaml at STACKS_SHA
- **AND** every `portainer_stack` keeps `repository_reference_name = refs/heads/main`

#### Scenario: Webhook redeploy
- **WHEN** a stack webhook is triggered after the apply
- **THEN** Portainer redeploys from the compose file at `compose_path` on the configured reference, independent of STACKS_SHA

### Requirement: Swarm GitOps Stack Resources
For each Portainer-managed stack the module SHALL manage a `portainer_stack` named after the stack with `deployment_type = "swarm"`, `method = "repository"`, `endpoint_id` from the variable, and `stack_webhook`, `pull_image` and `force_update` set to true. Git repository authentication SHALL be enabled, with `repository_username`/`repository_password`, only when both `git_username` and `git_password` are non-null.

#### Scenario: Default CI invocation without git credentials
- **WHEN** neither `git_username` nor `git_password` is set
- **THEN** each stack has `git_repository_authentication = false` and null repository credentials

#### Scenario: Stack leaves the managed set
- **WHEN** a stack is removed from stacks.yaml or its `portainer_managed` becomes false
- **THEN** the plan destroys its `portainer_stack` and its `WEBHOOK_URL_<NAME>` Infisical secret

### Requirement: Per-Stack Environment Injection
Each Portainer stack SHALL receive as `env` entries the map in `local.portainer_stack_envs` keyed by its name, built from Infisical env `prod` folders `/infrastructure`, `/stacks/gateway`, `/stacks/identity`, `/stacks/network`, `/stacks/observability`, `/stacks/ai-interface` and `/stacks/uptime`. Maps SHALL exist for gateway, auth, network, observability, ai-interface, uptime, home-dashboard and cloud, each including BASE_DOMAIN from `/infrastructure`.

#### Scenario: Derived auth values
- **WHEN** the auth stack env is built
- **THEN** it sets AUTH_SESSION_COOKIES_0_AUTHELIA_URL to `https://auth.<BASE_DOMAIN>` and AUTH_SESSION_COOKIES_0_DEFAULT_REDIRECTION_URL to `https://home.<BASE_DOMAIN>`
- **AND** it maps AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY to AUTH_OIDC_JWKS_0_KEY and AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET to AUTH_GRAFANA_OIDC_CLIENT_SECRET_HASH

#### Scenario: Optional and fixed values
- **WHEN** DOCKER_SOCKET_PROXY_URL is absent from `/stacks/gateway` or ARCH_PC_IP is absent from `/stacks/ai-interface`
- **THEN** the corresponding env value is an empty string
- **AND** home-dashboard always receives HOME_ASSISTANT_URL `http://192.168.1.6:8123`

#### Scenario: Missing required secret or env map
- **WHEN** a non-optional key such as `/stacks/identity` POSTGRES_PASSWORD is missing, or a managed stack has no entry in `local.portainer_stack_envs`
- **THEN** Terraform planning fails on the map lookup

### Requirement: Webhook URL Publication
For every managed stack the module SHALL write the stack's Portainer webhook URL to Infisical env `prod` folder `/deployments` as `WEBHOOK_URL_<NAME>` (stack name upper-cased with `-` replaced by `_`). It SHALL also write `PORTAINER_WEBHOOK_URLS` in `/deployments` as the comma-joined webhook URLs of all managed stacks.

#### Scenario: Hyphenated stack name
- **WHEN** the `ai-interface` stack is created
- **THEN** its webhook URL is stored as `/deployments/WEBHOOK_URL_AI_INTERFACE`

#### Scenario: Combined list
- **WHEN** the apply completes with eight managed stacks
- **THEN** `/deployments/PORTAINER_WEBHOOK_URLS` holds the eight webhook URLs joined with `,` in stack-name order

### Requirement: Advisory Manifest Checks
The module SHALL declare Terraform `check` blocks asserting that `stacks_sha` is only combined with a GitHub `repository_url`, that the manifest has `version: 1`, that every managed stack has a non-blank `compose_path`, and that every managed stack has an env map. A failing check SHALL be reported as a warning and SHALL NOT by itself fail plan or apply.

#### Scenario: Wrong manifest version
- **WHEN** the fetched stacks.yaml has `version: 2`
- **THEN** the plan reports the warning "stacks.yaml must define version: 1." and continues using the manifest's stacks

#### Scenario: Blank compose path
- **WHEN** a managed stack has `compose_path: ""`
- **THEN** the plan reports the `stacks_manifest_compose_paths` warning

### Requirement: Portainer Pipeline Stage Order
After the Ansible layer the pipeline SHALL run, sequentially: post-bootstrap-secret-check when RUN_PORTAINER_APPLY is true; the `sync-configs` Ansible run when RUN_CONFIG_SYNC is true; portainer-api-preflight when RUN_PORTAINER_APPLY or RUN_HEALTH_REDEPLOY is true; portainer-apply-debug then portainer-apply when RUN_PORTAINER_APPLY is true; and health-gated-redeploy last when RUN_HEALTH_REDEPLOY is true. These Dagger stages SHALL be bound to the Tailscale SOCKS5 proxy when available.

#### Scenario: Stacks SHA bump run
- **WHEN** RUN_PORTAINER_APPLY, RUN_CONFIG_SYNC and RUN_HEALTH_REDEPLOY are all true
- **THEN** the stages run in the order post-bootstrap-secret-check, sync-configs, portainer-api-preflight, portainer-apply-debug, portainer-apply, health-gated-redeploy

#### Scenario: Stage failure
- **WHEN** any of these stages exits non-zero
- **THEN** no later stage runs and the pipeline exits with status 1

#### Scenario: Post-bootstrap secret gate
- **WHEN** post-bootstrap-secret-check finds PORTAINER_API_URL, PORTAINER_API_KEY, PORTAINER_ADMIN_PASSWORD or PORTAINER_ADMIN_PASSWORD_HASH missing or invalid, or cannot validate or rotate the API key
- **THEN** it fails and portainer-api-preflight and portainer-apply do not run

### Requirement: Portainer API Reachability Preflight
portainer-api-preflight SHALL read PORTAINER_API_URL from Infisical `/management` and fail when it is empty. It SHALL strip a trailing `/` and `/api` from the URL, GET `<base>/api/system/status` with a 10-second timeout, and pass only when the HTTP status is 200 or 401; SSH reachability checks SHALL be disabled for this stage.

#### Scenario: Portainer answers 401
- **WHEN** `<base>/api/system/status` returns HTTP 401
- **THEN** the preflight prints "Portainer API preflight passed (HTTP 401)." and succeeds

#### Scenario: Portainer unreachable or unexpected status
- **WHEN** the request times out or returns a status other than 200 or 401
- **THEN** the preflight fails with "Portainer API preflight failed (expected 200 or 401, got <status>)."

### Requirement: Portainer Environment Resolution
portainer-apply and portainer-apply-debug SHALL obtain a JWT from `POST <PORTAINER_API_URL>/auth` using PORTAINER_ADMIN_USER (default `admin`) and `/stacks/management` PORTAINER_ADMIN_PASSWORD, list `<PORTAINER_API_URL>/endpoints`, and resolve the environment ID as the single endpoint named `primary`, else the only endpoint when exactly one exists. Otherwise they MUST fail.

#### Scenario: Endpoint named primary
- **WHEN** Portainer lists several environments and exactly one is named `primary`
- **THEN** that environment's `Id` is used as `TF_VAR_portainer_endpoint_id`

#### Scenario: Unresolvable environment
- **WHEN** Portainer lists no environments, or several environments without a unique `primary`
- **THEN** the stage fails, listing the visible endpoints when more than zero exist

#### Scenario: Debug diagnostics gate
- **WHEN** portainer-apply-debug runs
- **THEN** it prints the TFC organization, workspace, stacks_sha, shadow_mode, Terraform version, workspace attributes (operations, execution-mode, auto-apply, locked, VCS repo, working directory), the Portainer environments and the resolved ID
- **AND** a failed TFC or Portainer request fails the stage before portainer-apply runs

### Requirement: Portainer Terraform Apply Stage
portainer_apply.sh SHALL assert that TFC workspace TFC_WORKSPACE_PORTAINER has `operations=false`, run `terraform init -reconfigure` in terraform/portainer-root with a generated backend config naming TFC_ORGANIZATION and that workspace, run `plan -detailed-exitcode -out=portainer.tfplan` with TF_VAR_portainer_endpoint_id and, when set, TF_VAR_stacks_sha, and apply the saved plan with `-auto-approve` only when it has changes and SHADOW_MODE is not true.

#### Scenario: No changes
- **WHEN** the plan exits 0
- **THEN** the stage prints "Terraform plan shows no changes — skipping apply." and succeeds without applying

#### Scenario: Shadow mode with changes
- **WHEN** the plan reports changes and SHADOW_MODE is true, 1 or yes
- **THEN** the stage skips apply and succeeds

#### Scenario: Workspace not in local operations mode
- **WHEN** the TFC workspace reports `operations` as true or null
- **THEN** the stage fails with "Workspace '<name>' is not configured for local operations." before `terraform init`

#### Scenario: Plan error
- **WHEN** the plan exits 1
- **THEN** the stage fails with "Terraform plan failed."

### Requirement: Health Redeploy Activation
The execution context SHALL set run_health_redeploy to true only for a push whose changed files include the `stacks` gitlink and are otherwise only `.gitmodules`, and for a workflow_dispatch with input `force_health_redeploy` true. Every other push SHALL leave it false.

#### Scenario: Stacks gitlink bump
- **WHEN** a push to main changes only `stacks` (optionally with `.gitmodules`)
- **THEN** run_health_redeploy, run_portainer_apply, run_host_sync and run_config_sync are true, infra apply and Ansible bootstrap are false, and the reason is `infra-repo-stacks-sha-bump`

#### Scenario: Other pushes
- **WHEN** a push changes Terraform or Ansible files
- **THEN** run_health_redeploy is false even though Portainer apply runs

#### Scenario: Manual dispatch
- **WHEN** the workflow is dispatched with `force_health_redeploy: true`
- **THEN** run_health_redeploy is true alongside run_portainer_apply

### Requirement: Health Redeploy Stage Environment
health_gated_redeploy.sh SHALL check out STACKS_SHA in the `stacks` directory when it is set, bootstrapping a shallow fetch from `https://github.com/JoseStud/stacks` when that directory is not a git work tree, then log in to Infisical. It SHALL exit 0 without triggering webhooks when SHADOW_MODE is true; otherwise it SHALL run trigger_webhooks_with_gates.sh on `stacks/stacks.yaml` under `infisical run --path=/deployments`.

#### Scenario: Shadow mode
- **WHEN** SHADOW_MODE is true
- **THEN** the stage prints "SHADOW_MODE=true: skipping webhook trigger mutations." and exits 0 without calling any webhook

#### Scenario: Manifest at the trusted SHA
- **WHEN** STACKS_SHA is set
- **THEN** stack order, dependencies and health settings come from stacks.yaml at STACKS_SHA
- **AND** the WEBHOOK_URL_* variables come from Infisical `/deployments`

### Requirement: Health-Gated Redeploy Sequencing
The gate script SHALL redeploy every `portainer_managed: true` stack, failing when there are none, in depends_on topological order that follows only Portainer-managed dependencies and fails on a cycle. For each stack it SHALL wait for each listed dependency's health, trigger the stack webhook, then wait for the stack's own health, stopping at the first failure, and SHALL abort before a stack once REDEPLOY_TIMEOUT_SECONDS (default 2400) have elapsed.

#### Scenario: Current manifest order
- **WHEN** the manifest in stacks/stacks.yaml is redeployed
- **THEN** stacks are processed as gateway, auth, network, observability, ai-interface, home-dashboard, uptime, cloud
- **AND** gateway health is checked before auth's webhook, and gateway and auth health before each later stack's webhook

#### Scenario: Dependency cycle
- **WHEN** two managed stacks depend on each other
- **THEN** the script prints "Dependency cycle detected at stack '<name>'." and exits 1 before triggering any webhook

#### Scenario: Overall deadline exceeded
- **WHEN** REDEPLOY_TIMEOUT_SECONDS have elapsed before the next stack starts
- **THEN** the script prints "Overall redeploy deadline exceeded (<n>s). Aborting remaining stacks." and exits 1

### Requirement: Stack Health Gate Evaluation
A health gate SHALL pass immediately for a stack without `healthcheck_url`. Otherwise it SHALL render the URL with gomplate, using BASE_DOMAIN fetched from Infisical `/infrastructure`, and poll it every 5 seconds with a 10-second request timeout until the status equals `healthcheck_expected_status` (default 200), failing after `healthcheck_timeout_seconds` (default 300).

#### Scenario: Templated gateway health URL
- **WHEN** gateway's `healthcheck_url` is `https://gateway-health.{{ .Env.BASE_DOMAIN }}/healthz`
- **THEN** the gate polls `https://gateway-health.<BASE_DOMAIN>/healthz` until it returns HTTP 200

#### Scenario: Health timeout
- **WHEN** the expected status is not observed within the timeout
- **THEN** the script prints "Health check timed out for <stack>. Last status: <status>." and the redeploy fails

### Requirement: Webhook Trigger With Retry
The gate script SHALL POST to the URL in environment variable `WEBHOOK_URL_<NAME>` (stack name upper-cased, `-` replaced by `_`), treating any 2xx status as success. It SHALL retry HTTP 5xx responses for up to 3 attempts in total with 2-second then 4-second delays, and SHALL fail on a 4xx response or when the variable is missing.

#### Scenario: Transient server error
- **WHEN** the first webhook POST returns HTTP 502 and the second returns 204
- **THEN** the script waits 2 seconds, retries, and reports "Triggered webhook for <stack> (HTTP 204)."

#### Scenario: Missing webhook URL
- **WHEN** `WEBHOOK_URL_<NAME>` is unset for a managed stack
- **THEN** the script prints "Missing WEBHOOK_URL_<NAME> for stack '<stack>'." and the redeploy fails

### Requirement: Manual Webhook Trigger Script
scripts/portainer-webhook.sh SHALL POST to each webhook URL passed as arguments or, when there are none, to each comma-separated entry of WEBHOOK_URLS (whitespace-trimmed, blanks skipped), printing only the last path segment of each URL. It SHALL exit 0 only when every call returns HTTP 200 or 204, and SHALL print usage and exit 1 when neither source is provided.

#### Scenario: All webhooks succeed
- **WHEN** every URL returns HTTP 200 or 204
- **THEN** the script prints "All webhooks triggered successfully." and exits 0

#### Scenario: A webhook fails
- **WHEN** a call returns a status other than 200 or 204
- **THEN** the script exits with a non-zero status

#### Scenario: No URLs supplied
- **WHEN** no arguments are given and WEBHOOK_URLS is empty
- **THEN** the script prints usage text and exits 1
