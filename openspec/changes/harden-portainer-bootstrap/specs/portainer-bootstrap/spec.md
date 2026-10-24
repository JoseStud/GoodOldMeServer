# Spec Delta

## ADDED Requirements

### Requirement: Portainer Data Reset Only On Explicit Request
The role SHALL NOT remove the `management` stack, the `management_portainer-server` service or the `management_portainer_db` volume unless `portainer_force_reset` is true. With it, the role SHALL remove only `management_portainer-server`, wait until no container uses the volume, archive the volume to a root-only timestamped tarball under `/mnt/app_data/backups/portainer/`, verify the archive, and only then remove the volume before the normal deploy.

#### Scenario: Unhealthy Portainer without the reset flag
- **WHEN** the `management` stack exists, Portainer is restarting, crash-looping or answering `/system/status` with a non-200 status, and `portainer_force_reset` is unset or false
- **THEN** the role runs no `docker stack rm`, `docker service rm` or `docker volume rm`, deploys the stack normally and leaves `management_portainer_db` in place

#### Scenario: Explicit reset
- **WHEN** the operator runs phase 6 with `-e portainer_force_reset=true` and `management_portainer_db` exists on the primary manager
- **THEN** the role removes `management_portainer-server` only, leaving `homarr`, `homarr-db` and `portainer-agent` running, and waits until no container references the volume
- **AND** it writes `/mnt/app_data/backups/portainer/management_portainer_db-<UTC timestamp>.tar.gz` (directory mode 0700, file mode 0600, owner root) and lists the archive successfully before removing the volume
- **AND** the normal deploy then recreates `portainer-server`, which initializes an empty database with the resolved admin hash

#### Scenario: Archive fails
- **WHEN** the reset is requested and the archive cannot be written or listed
- **THEN** the role fails without removing `management_portainer_db`
- **AND** its message states that the volume is intact and that re-running phase 6 without the flag recreates `portainer-server`

#### Scenario: Nothing to reset
- **WHEN** `portainer_force_reset` is true but `management_portainer_db` does not exist on the primary manager
- **THEN** no archive is written, the role reports that there was nothing to reset, and the deploy proceeds

#### Scenario: Orchestrator run
- **WHEN** phase 6 runs from `.github/scripts/stages/ansible_run.sh`, which passes no extra-vars to `ansible-playbook`
- **THEN** the reset path never runs

### Requirement: Credential-Safe Task Output
Phase 6 SHALL NOT print `PORTAINER_ADMIN_PASSWORD`, the admin bcrypt hash, a Portainer JWT or API key, `HOMARR_SECRET_KEY`, `HOMARR_DB_PASS`, HTTP request headers or verbose HTTP client output. Every task whose arguments, environment or result carry one of these SHALL set `no_log`, and no task SHALL print such a task's arguments, environment or response body. Failure messages SHALL contain only step names, HTTP status codes, exit codes, counts and Swarm task states.

#### Scenario: First bootstrap with no endpoint
- **WHEN** phase 6 runs against a Portainer instance that has zero endpoints
- **THEN** the Ansible output contains no `Authorization` header, JWT, API key, password, bcrypt hash or verbose curl lines

#### Scenario: Task carrying a credential fails
- **WHEN** a task that sends the JWT or API key fails (token listing, token deletion or creation, endpoint provisioning, final verification), or the stack deploy fails
- **THEN** the output shows the task name and a message limited to the failing step and its HTTP status or exit code
- **AND** the task's arguments, environment and response body are not shown

#### Scenario: Static review of the role
- **WHEN** `ansible/roles/portainer_bootstrap/tasks/main.yml` is inspected
- **THEN** no task invokes `curl` with `-v` or `-sv`, and no task prints the raw stdout, stderr or response of a task that ran with `no_log`; only parsed step markers and status codes are echoed
- **AND** every task whose module arguments or `environment` reference `portainer_admin_password`, `portainer_admin_password_hash`, `portainer_jwt`, `portainer_api_key`, `portainer_api_key_candidate`, `HOMARR_SECRET_KEY` or `HOMARR_DB_PASS` sets `no_log: true`

## MODIFIED Requirements

### Requirement: Admin Password Hash Generation
The role SHALL fail before changing the host when `PORTAINER_ADMIN_PASSWORD` is empty. It SHALL reuse the controller's `PORTAINER_ADMIN_PASSWORD_HASH` when that value is a bcrypt hash that verifies against `PORTAINER_ADMIN_PASSWORD`. Otherwise it SHALL generate a new hash with `password_hash('bcrypt', rounds=portainer_bcrypt_rounds)` (default 12) and, when `INFISICAL_PROJECT_ID` is set, write it to Infisical `/stacks/management` in env `prod` before the deploy.

#### Scenario: Stored hash verifies
- **WHEN** the controller environment holds `PORTAINER_ADMIN_PASSWORD_HASH` (injected from Infisical `/stacks/management` by `.github/scripts/stages/ansible_run.sh`) and recomputing bcrypt over `PORTAINER_ADMIN_PASSWORD` with that hash's variant, cost and salt reproduces it exactly
- **THEN** that hash is passed to the `management` deploy unchanged and no `infisical secrets set PORTAINER_ADMIN_PASSWORD_HASH` runs
- **AND** the hash does not change the `portainer-server` service spec, so a re-run with unchanged inputs starts no new `portainer-server` task

#### Scenario: Hash regenerated and persisted
- **WHEN** `PORTAINER_ADMIN_PASSWORD_HASH` is empty, is not a bcrypt hash, or does not verify against `PORTAINER_ADMIN_PASSWORD` (for example after the password changed in Infisical)
- **THEN** a freshly salted hash is generated without logging and used for the `management` deploy
- **AND** with `INFISICAL_PROJECT_ID` set, the controller runs `infisical secrets set PORTAINER_ADMIN_PASSWORD_HASH=<hash> --env=prod --path=/stacks/management` once (delegated to localhost, without logging) before the deploy, and a non-zero exit fails the role

#### Scenario: No Infisical project ID
- **WHEN** `INFISICAL_PROJECT_ID` is empty and a new hash had to be generated
- **THEN** the hash is still passed to the deploy but is not written to Infisical
- **AND** the final summary reports the admin hash as `MANUAL — set PORTAINER_ADMIN_PASSWORD_HASH in Infisical /stacks/management`

#### Scenario: Admin password missing
- **WHEN** `PORTAINER_ADMIN_PASSWORD` is unset or empty on the controller
- **THEN** the role fails before creating `/opt/stacks/management`, staging the compose file or deploying, and no hash is generated or written

### Requirement: Management Stack Deployment
After ensuring the attachable overlay network `traefik_proxy` exists, the role SHALL run `docker stack deploy --compose-file /opt/stacks/management/docker-compose.yml --with-registry-auth management` without logging. Its environment SHALL be exactly the set `stacks/management/.env.tmpl` renders for the runtime agent: `BASE_DOMAIN`, `TZ`, `HOMARR_SECRET_KEY` and `HOMARR_DB_PASS` from the controller environment, with no defaults, plus the resolved `PORTAINER_ADMIN_PASSWORD_HASH`.

#### Scenario: Deploy with controller-provided values
- **WHEN** `BASE_DOMAIN`, `TZ`, `HOMARR_SECRET_KEY` and `HOMARR_DB_PASS` are non-empty in the controller environment (`.github/scripts/stages/ansible_run.sh` injects Infisical `/infrastructure` and `/stacks/management`, the same paths and keys `stacks/management/.env.tmpl` reads)
- **THEN** the deploy command receives those four values together with the resolved `PORTAINER_ADMIN_PASSWORD_HASH`, and the role sets no other compose variable
- **AND** the task reports changed when its stdout contains `Creating service` or `Updating service`

#### Scenario: Optional values missing
- **WHEN** `HOMARR_SECRET_KEY` or `TZ`, which used to fall back to `changeme` and `Etc/UTC`, is unset or empty on the controller
- **THEN** the role fails before creating `/opt/stacks/management`, staging the compose file or deploying, with a message that names only the missing variables
- **AND** no `changeme` or `Etc/UTC` value is substituted and no deploy runs

#### Scenario: Required value missing
- **WHEN** `BASE_DOMAIN` or `HOMARR_DB_PASS` is unset or empty on the controller
- **THEN** the role fails in the same way before any host change, naming only the missing variables
- **AND** `localhost` is not substituted for `BASE_DOMAIN` and the deploy never runs with a blank `HOMARR_DB_PASS`

#### Scenario: Re-run with unchanged inputs
- **WHEN** phase 6 runs again with the same Infisical values and the stored admin hash verifies
- **THEN** the deploy leaves the environment-derived parts of the `homarr`, `homarr-db` and `portainer-server` service specs unchanged, so Swarm starts no new task for them unless their image changed

### Requirement: Portainer Readiness And Authentication
After deploying, the role SHALL wait until `docker service ps management_portainer-agent --filter desired-state=Running` lists a task whose current state starts with `Running` (24 retries, 5 s delay). It SHALL then wait for `GET {{ portainer_api_url }}/system/status` to return 200 (`portainer_health_timeout / 5` retries, default 120 s giving 24, 5 s delay). Finally it SHALL `POST /auth` as `portainer_admin_user` (default `admin`) with `PORTAINER_ADMIN_PASSWORD` and keep the JWT.

#### Scenario: Portainer becomes ready
- **WHEN** the agent has a Running task and the status endpoint returns 200 within the retries
- **THEN** the role posts the credentials to `{{ portainer_api_url }}/auth` without logging them, expects HTTP 200, and stores the response's `jwt` as `portainer_jwt`

#### Scenario: Readiness or authentication failure
- **WHEN** the agent task never reaches Running, the status endpoint never returns 200 within the retries, or `/auth` returns a status other than 200
- **THEN** the role fails before endpoint provisioning, any API key handling or any `/management` Infisical write
- **AND** no stack, service or volume is removed

#### Scenario: Portainer stays unhealthy after deploy
- **WHEN** either readiness wait runs out of retries
- **THEN** the role prints the name, current state and error of each `management_portainer-server` and `management_portainer-agent` task, and nothing from container logs, service inspection or HTTP responses
- **AND** its failure message states that no data was removed and names `-e portainer_force_reset=true` as the explicit way to rebuild Portainer from an empty database after an archive

### Requirement: Agent Endpoint Provisioning
The role SHALL ensure the agent endpoint with one idempotent task that runs without logging. Each attempt authenticates with a fresh JWT, lists `/endpoints` and, only when none exist, POSTs the agent endpoint (`Name=primary`, `EndpointCreationType=2`, `URL=tcp://tasks.portainer-agent:9001`, TLS with skip-verify). The task retries 12 times with a 5 s delay. No diagnostic or verbose HTTP task SHALL run before or after it.

#### Scenario: No endpoint registered
- **WHEN** `GET {{ portainer_api_url }}/endpoints` returns an empty list
- **THEN** the task sends the multipart create request (`TLS=true`, `TLSSkipVerify=true`, `TLSSkipClientVerify=true`) without verbose client output and reports changed when it prints `CHANGED`
- **AND** the Ansible output contains no request headers, JWT or response body

#### Scenario: Endpoint already exists
- **WHEN** at least one endpoint is listed
- **THEN** the task prints `UNCHANGED` and reports no change

#### Scenario: Endpoint cannot be ensured
- **WHEN** authentication, listing or creation keeps failing after all 12 retries
- **THEN** the role fails with a message naming only the failing step (`auth`, `list` or `create`) and its HTTP status code

### Requirement: Final Verification And Summary
When an API key was determined, the role SHALL send `GET /system/status` with that key in `X-API-Key`, without logging, and require HTTP 200. It SHALL then print a summary with the UI URL `https://portainer.<BASE_DOMAIN>`, the Tailscale API URL, where the API key was written (or that it must be set manually), the admin hash mode (reused, written or manual), the key mode, the stack services, and a health value of `OK` or `SKIPPED`.

#### Scenario: Successful bootstrap
- **WHEN** the verification request returns HTTP 200
- **THEN** the summary's `Health` line shows `OK` and its `Key Mode` line shows `reused-existing-key` or `rotated-new-key`
- **AND** its `Admin Hash` line shows `reused (verified against PORTAINER_ADMIN_PASSWORD)`, `written to Infisical /stacks/management` or the `MANUAL — …` text

#### Scenario: Verification fails
- **WHEN** the verification request returns a status other than 200
- **THEN** the role fails with a message giving only the HTTP status code, and the summary is not printed

#### Scenario: Tailscale IP unavailable
- **WHEN** `ts_ip` is not defined
- **THEN** the summary shows the API URL as `http://(ts_ip unavailable):9000/api (Tailscale)`

## REMOVED Requirements

### Requirement: Unhealthy Portainer Reset Before Deploy
**Reason**: A single non-retried, non-failing status probe decided whether to delete `management_portainer_db`. Any transient non-200 answer therefore wiped Portainer's database, for example during a restart, an OOM kill or an image upgrade. That database holds the stacks, webhooks, license, agent endpoint and API tokens, and the wipe left Terraform state and the `/deployments` webhook secrets pointing at objects that no longer existed.
**Migration**: Phase 6 now always deploys over the existing volume. If Portainer stays unhealthy, "Portainer Readiness And Authentication" fails the run with safe diagnostics. To rebuild Portainer from an empty database, the operator runs phase 6 locally with `-e portainer_force_reset=true` (see "Portainer Data Reset Only On Explicit Request"), which archives the volume first. They then re-run `terraform/portainer-root` apply so that the stacks, webhooks (`/deployments` `WEBHOOK_URL_*`) and license are recreated.
