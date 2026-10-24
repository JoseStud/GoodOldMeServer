# portainer-bootstrap Specification

## Purpose
Phase 6 of `ansible/playbooks/provision.yml` (role `ansible/roles/portainer_bootstrap`): bring up the Ansible-owned `management` Docker Swarm stack (Portainer server, Portainer agent, Homarr) on the primary OCI manager. It also registers the Portainer agent endpoint, makes sure a working Portainer API key exists, and writes Portainer credentials back to Infisical for later automation.

## Requirements

### Requirement: Primary Manager Compose Staging
The role SHALL act only on `groups['oci_nodes'][0]`: the playbook include and every task in the role are gated on that host. Before deploying, it SHALL ensure `/opt/stacks/management` exists (root:root, mode 0750) and copy the controller's trusted `stacks/management/docker-compose.yml` to `/opt/stacks/management/docker-compose.yml` (root:root, mode 0644).

#### Scenario: Non-primary host
- **WHEN** phase 6 is evaluated for a host other than the first `oci_nodes` host (the second OCI node or the GCP witness)
- **THEN** the role is not included for that host and no management stack action runs there

#### Scenario: Compose staged from the controller checkout
- **WHEN** the role runs on the primary manager
- **THEN** `/opt/stacks/management/docker-compose.yml` is overwritten with the controller's `stacks/management/docker-compose.yml` before any stack deploy

### Requirement: Admin Password Hash Generation
On every run the role SHALL generate a new bcrypt hash of `PORTAINER_ADMIN_PASSWORD` from the controller environment, using `password_hash('bcrypt', rounds=portainer_bcrypt_rounds)` with `portainer_bcrypt_rounds` defaulting to 12. It SHALL pass that hash to the stack deploy as `PORTAINER_ADMIN_PASSWORD_HASH` and, when `INFISICAL_PROJECT_ID` is set, write it to Infisical `/stacks/management` in env `prod`.

#### Scenario: Hash regenerated and persisted
- **WHEN** the role runs with `INFISICAL_PROJECT_ID` set, whether or not `PORTAINER_ADMIN_PASSWORD` changed since the last run
- **THEN** a freshly salted hash is generated without logging and used for the `management` deploy
- **AND** the controller runs `infisical secrets set PORTAINER_ADMIN_PASSWORD_HASH=<hash> --env=prod --path=/stacks/management` once (delegated to localhost), and a non-zero exit fails the role

#### Scenario: No Infisical project ID
- **WHEN** `INFISICAL_PROJECT_ID` is empty
- **THEN** the hash is still passed to the deploy but is not written to Infisical
- **AND** the final summary reports the admin hash as `MANUAL — set PORTAINER_ADMIN_PASSWORD_HASH in Infisical /stacks/management`

### Requirement: Unhealthy Portainer Reset Before Deploy
Before deploying, the role SHALL make a single GET to `{{ portainer_api_url }}/system/status` (default `http://localhost:9000/api`) that never fails the task. When the earlier `docker stack services management` check exited 0 and that status is not 200, it SHALL run `docker stack rm management` and wait for its services to stop. Separately, whenever that status is not 200, it SHALL run `docker volume rm management_portainer_db` and ignore any failure.

#### Scenario: Portainer healthy
- **WHEN** the pre-deploy status request returns HTTP 200
- **THEN** neither `docker stack rm management` nor `docker volume rm management_portainer_db` runs

#### Scenario: Stack present but Portainer unhealthy
- **WHEN** `docker stack services management` exited 0 and the pre-deploy status is not 200, including a connection failure
- **THEN** `docker stack rm management` runs, ignoring failures, and if it exited 0 the role polls `docker service ls --filter label=com.docker.stack.namespace=management -q` up to 24 retries at 5-second intervals until it prints nothing, failing the role if services remain
- **AND** `docker volume rm management_portainer_db` runs, its failure is ignored and the task always reports changed

#### Scenario: Nothing listening yet
- **WHEN** no Portainer answers on the API URL, for example on first bootstrap
- **THEN** `docker volume rm management_portainer_db` is still attempted and a missing-volume error does not fail the role

### Requirement: Management Stack Deployment
After ensuring the attachable overlay network `traefik_proxy` exists, the role SHALL run `docker stack deploy --compose-file /opt/stacks/management/docker-compose.yml --with-registry-auth management`. The only environment it SHALL add is `BASE_DOMAIN` (controller env, default `localhost`), `HOMARR_SECRET_KEY` (default `changeme`), `TZ` (default `Etc/UTC`) and `PORTAINER_ADMIN_PASSWORD_HASH` (the hash generated in this run).

#### Scenario: Deploy with controller-provided values
- **WHEN** `BASE_DOMAIN`, `HOMARR_SECRET_KEY` and `TZ` are present in the controller environment (`.github/scripts/stages/ansible_run.sh` injects Infisical `/infrastructure` and `/stacks/management` into the playbook environment)
- **THEN** the deploy command receives those values together with `PORTAINER_ADMIN_PASSWORD_HASH`
- **AND** the task reports changed when its stdout contains `Creating service` or `Updating service`

#### Scenario: Optional values missing
- **WHEN** `HOMARR_SECRET_KEY` or `TZ` is unset or empty on the controller
- **THEN** `changeme` or `Etc/UTC` is passed in its place
- **AND** the role sets no other compose variable for the deploy

### Requirement: Portainer Readiness And Authentication
After deploying, the role SHALL wait until `docker service ps management_portainer-agent --filter desired-state=Running` lists a task whose current state starts with `Running` (24 retries, 5 s delay). It SHALL then wait for `GET {{ portainer_api_url }}/system/status` to return 200 (`portainer_health_timeout / 5` retries, default 120 s giving 24, 5 s delay). Finally it SHALL `POST /auth` as `portainer_admin_user` (default `admin`) with `PORTAINER_ADMIN_PASSWORD` and keep the JWT.

#### Scenario: Portainer becomes ready
- **WHEN** the agent has a Running task and the status endpoint returns 200 within the retries
- **THEN** the role posts the credentials to `{{ portainer_api_url }}/auth` without logging them, expects HTTP 200, and stores the response's `jwt` as `portainer_jwt`

#### Scenario: Readiness or authentication failure
- **WHEN** the agent task never reaches Running, the status endpoint never returns 200 within the retries, or `/auth` returns a status other than 200
- **THEN** the role fails before any API key handling or Infisical write

### Requirement: Agent Endpoint Provisioning
The role SHALL first run a diagnostic shell task, whose failures are ignored, that authenticates, lists `/endpoints` and, when none exist, POSTs the agent endpoint (`Name=primary`, `EndpointCreationType=2`, `URL=tcp://tasks.portainer-agent:9001`, TLS with skip-verify) using `curl -sv`. A debug task SHALL then print that task's stdout and stderr lines. Next, an idempotent task SHALL re-authenticate and create the endpoint only when none exist, retrying 12 times with a 5 s delay.

#### Scenario: No endpoint registered
- **WHEN** `GET {{ portainer_api_url }}/endpoints` returns an empty list
- **THEN** the diagnostic task sends the multipart create request (`TLS=true`, `TLSSkipVerify=true`, `TLSSkipClientVerify=true`) with verbose curl output, including request headers, merged into its stdout
- **AND** the following debug task prints those lines to the Ansible output, and the idempotent task authenticates again with a fresh JWT, lists endpoints again and creates the endpoint only if the list is still empty, reporting changed when it prints `CHANGED`

#### Scenario: Endpoint already exists
- **WHEN** at least one endpoint is listed
- **THEN** the diagnostic task prints `Endpoint already exists — nothing to create` and the idempotent task prints `UNCHANGED` and reports no change

#### Scenario: Endpoint cannot be ensured
- **WHEN** the idempotent task's authentication, listing or creation keeps failing after all 12 retries
- **THEN** the role fails, while failures in the diagnostic task alone never fail the role

### Requirement: API Key Candidate Resolution
The role SHALL take its API key candidate from the controller environment variable `PORTAINER_API_KEY`, trimmed. When that is empty and `INFISICAL_PROJECT_ID` is set, it SHALL run `infisical secrets get PORTAINER_API_KEY --env=prod --path=/management --projectId=<INFISICAL_PROJECT_ID> --plain --silent` once on the controller, ignoring failures. It SHALL use the trimmed output as the candidate when the command exits 0 with non-empty output.

#### Scenario: Candidate from environment
- **WHEN** `PORTAINER_API_KEY` is non-empty in the controller environment
- **THEN** that value is the candidate and no Infisical lookup runs

#### Scenario: Candidate from Infisical fallback
- **WHEN** `PORTAINER_API_KEY` is empty, `INFISICAL_PROJECT_ID` is set, and the Infisical lookup exits 0 with non-empty output
- **THEN** the trimmed lookup output becomes the candidate

#### Scenario: No candidate available
- **WHEN** the environment value is empty and the lookup is skipped, fails or returns nothing
- **THEN** the candidate stays empty and the role takes the rotation path

### Requirement: API Key Reuse Or Rotation
When the candidate is non-empty, the role SHALL call `GET /system/status` with header `X-API-Key: <candidate>`, accept HTTP 200, 401 or 403, and reuse the candidate on 200. Otherwise it SHALL delete every token from `GET /users/1/tokens` whose description equals `portainer_api_token_description` (default `terraform-managed`), create a new token with that description via `POST /users/1/tokens`, and assert that the response has a non-empty `rawAPIKey`.

#### Scenario: Candidate accepted
- **WHEN** the validation request returns HTTP 200
- **THEN** `portainer_api_key` is set to the candidate with source `reused-existing-key`
- **AND** no tokens are deleted or created

#### Scenario: Rotation required
- **WHEN** the candidate is empty or the validation request returns 401 or 403
- **THEN** a warning reporting how many `terraform-managed` tokens will be deleted is printed when there are any, each one is deleted with the JWT (expecting 200 or 204), and a new token is created (expecting 200)
- **AND** `portainer_api_key` is set to the returned `rawAPIKey` with source `rotated-new-key`, or the role fails with `API key rotation was required, but Portainer did not return a raw API key.` if `rawAPIKey` is missing or empty

#### Scenario: Unexpected validation status
- **WHEN** the validation request returns a status other than 200, 401 or 403
- **THEN** the role fails without rotating or reusing a key

### Requirement: Infisical Credential Write-Back
When `INFISICAL_PROJECT_ID` is set, the role SHALL write the following to Infisical `/management` in env `prod`, from the controller (delegated to localhost, run once): `PORTAINER_URL=https://portainer.<BASE_DOMAIN>` only when the domain is not `localhost`; `PORTAINER_API_URL=http://<ts_ip>:9000/api` only when the `ts_ip` fact (set by the phase 5 swarm role) is defined; and `PORTAINER_API_KEY` whenever an API key was determined.

#### Scenario: Full write-back
- **WHEN** `INFISICAL_PROJECT_ID` is set, `BASE_DOMAIN` is not `localhost`, `ts_ip` is defined and an API key was reused or rotated
- **THEN** three `infisical secrets set ... --env=prod --path=/management` commands write `PORTAINER_URL`, `PORTAINER_API_URL` and `PORTAINER_API_KEY`, the last one without logging
- **AND** `PORTAINER_API_KEY` is written even when the existing key was reused, and any non-zero CLI exit fails the role

#### Scenario: Tailscale IP fact missing
- **WHEN** the `ts_ip` fact is not defined on the primary manager
- **THEN** `PORTAINER_API_URL` is not written while the other writes still happen

#### Scenario: No Infisical project ID
- **WHEN** `INFISICAL_PROJECT_ID` is empty
- **THEN** none of the `/management` secrets are written and the summary reports `MANUAL — set PORTAINER_API_KEY in Infisical /management`

### Requirement: Final Verification And Summary
When an API key was determined, the role SHALL send `GET /system/status` with that key in `X-API-Key` and require HTTP 200. It SHALL then print a summary with the UI URL `https://portainer.<BASE_DOMAIN>`, the Tailscale API URL, where the API key and admin hash were written (or that they must be set manually), the key mode, the stack services, and a health value of `OK` or `SKIPPED`.

#### Scenario: Successful bootstrap
- **WHEN** the verification request returns HTTP 200
- **THEN** the summary's `Health` line shows `OK` and its `Key Mode` line shows `reused-existing-key` or `rotated-new-key`

#### Scenario: Verification fails
- **WHEN** the verification request returns a status other than 200
- **THEN** the role fails and the summary is not printed

#### Scenario: Tailscale IP unavailable
- **WHEN** `ts_ip` is not defined
- **THEN** the summary shows the API URL as `http://(ts_ip unavailable):9000/api (Tailscale)`
