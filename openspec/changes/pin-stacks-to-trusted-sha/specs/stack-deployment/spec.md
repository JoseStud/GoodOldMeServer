# Spec Delta

## MODIFIED Requirements

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
- **THEN** it uses `portainer_endpoint_id = 1`, `repository_url = https://github.com/JoseStud/stacks.git` and `repository_reference = refs/heads/deploy`
- **AND** it exposes `portainer_webhook_urls` (sensitive map of stack name to webhook URL) and `portainer_stack_ids` (map of stack name to Portainer stack ID)

### Requirement: Stack Source Repository Reference
Every Portainer stack SHALL be created from `repository_url` at `repository_reference` (default `refs/heads/deploy`) with `file_path_in_repository` set to the manifest `compose_path`. In orchestrator runs, the reference SHALL resolve to the trusted STACKS_SHA before any stack is created, updated or redeployed. Webhook redeploys therefore pull compose files from the same commit that supplies the manifest, `/opt/stacks` and the GlusterFS configs.

#### Scenario: CI apply with a trusted stacks SHA
- **WHEN** the pipeline runs portainer-apply with STACKS_SHA set and no `TF_VAR_repository_reference`
- **THEN** the stack list comes from stacks.yaml at STACKS_SHA
- **AND** every `portainer_stack` has `repository_reference_name = refs/heads/deploy`
- **AND** `refs/heads/deploy` in JoseStud/stacks resolves to STACKS_SHA

#### Scenario: Webhook redeploy
- **WHEN** a stack webhook is triggered after the run, by the health-gated redeploy or by the runtime agent's `portainer-stack-webhook` helper
- **THEN** Portainer redeploys the compose file at `compose_path` from the commit `refs/heads/deploy` points to, which is the last STACKS_SHA a run advanced the ref to
- **AND** a newer commit on stacks `main` is not deployed until an orchestrator run trusts it and advances the ref

#### Scenario: Reference switch from main
- **WHEN** the first apply runs after the default changes from `refs/heads/main` to `refs/heads/deploy`
- **THEN** each existing `portainer_stack` is updated in place, with no destroy or create
- **AND** each keeps its Portainer stack ID and webhook URL, so the `WEBHOOK_URL_*` secrets do not change

### Requirement: Portainer Pipeline Stage Order
After the Ansible layer the pipeline SHALL run, sequentially: post-bootstrap-secret-check when RUN_PORTAINER_APPLY is true; Ansible `sync-configs` when RUN_CONFIG_SYNC is true; portainer-api-preflight then stacks-deploy-ref when RUN_PORTAINER_APPLY or RUN_HEALTH_REDEPLOY is true; portainer-apply-debug then portainer-apply when RUN_PORTAINER_APPLY is true; and health-gated-redeploy last when RUN_HEALTH_REDEPLOY is true. These Dagger stages SHALL use the Tailscale SOCKS5 proxy when available.

#### Scenario: Stacks SHA bump run
- **WHEN** RUN_PORTAINER_APPLY, RUN_CONFIG_SYNC and RUN_HEALTH_REDEPLOY are all true
- **THEN** the stages run in the order post-bootstrap-secret-check, sync-configs, portainer-api-preflight, stacks-deploy-ref, portainer-apply-debug, portainer-apply, health-gated-redeploy

#### Scenario: Stage failure
- **WHEN** any of these stages exits non-zero
- **THEN** no later stage runs and the pipeline exits with status 1

#### Scenario: Deploy reference not advanced
- **WHEN** stacks-deploy-ref fails
- **THEN** portainer-apply-debug, portainer-apply and health-gated-redeploy do not run, and the run creates, updates and redeploys no Portainer stack

#### Scenario: Post-bootstrap secret gate
- **WHEN** post-bootstrap-secret-check finds PORTAINER_API_URL, PORTAINER_API_KEY, PORTAINER_ADMIN_PASSWORD or PORTAINER_ADMIN_PASSWORD_HASH missing or invalid, or cannot validate or rotate the API key
- **THEN** it fails and portainer-api-preflight and portainer-apply do not run

### Requirement: Portainer Terraform Apply Stage
portainer_apply.sh SHALL check out STACKS_SHA in the `stacks` directory when it is set, then assert that TFC workspace TFC_WORKSPACE_PORTAINER has `operations=false`, run `terraform init -reconfigure` in terraform/portainer-root with a generated backend config naming TFC_ORGANIZATION and that workspace, run `plan -detailed-exitcode -out=portainer.tfplan` with TF_VAR_portainer_endpoint_id, and apply the saved plan with `-auto-approve` only when it has changes and SHADOW_MODE is not true.

#### Scenario: Manifest pinned to STACKS_SHA
- **WHEN** STACKS_SHA is set
- **THEN** the `stacks/stacks.yaml` read by the plan is the file at STACKS_SHA, whatever the `stacks` directory held before the stage ran
- **AND** no `TF_VAR_stacks_sha` is passed to Terraform

#### Scenario: Stacks checkout failure
- **WHEN** STACKS_SHA cannot be fetched or checked out
- **THEN** the stage fails before `terraform init` and nothing is planned or applied

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
- **WHEN** the plan exits 1, including when a manifest plan guard fails
- **THEN** the stage fails with "Terraform plan failed." and applies nothing

### Requirement: Health Redeploy Stage Environment
health_gated_redeploy.sh SHALL check out STACKS_SHA in the `stacks` directory when it is set, bootstrapping a shallow fetch from `https://github.com/JoseStud/stacks` when that directory is not a git work tree, then log in to Infisical. It SHALL exit 0 without triggering webhooks when SHADOW_MODE is true; otherwise it SHALL fail unless `refs/heads/deploy` equals a non-empty STACKS_SHA, then run trigger_webhooks_with_gates.sh on `stacks/stacks.yaml` under `infisical run --path=/deployments`.

#### Scenario: Shadow mode
- **WHEN** SHADOW_MODE is true
- **THEN** the stage prints "SHADOW_MODE=true: skipping webhook trigger mutations." and exits 0 without calling any webhook

#### Scenario: Manifest at the trusted SHA
- **WHEN** STACKS_SHA is set
- **THEN** stack order, dependencies and health settings come from stacks.yaml at STACKS_SHA
- **AND** the WEBHOOK_URL_* variables come from Infisical `/deployments`

#### Scenario: Deploy reference drift
- **WHEN** SHADOW_MODE is not true and `refs/heads/deploy` is missing or resolves to a commit other than STACKS_SHA
- **THEN** the stage prints "refs/heads/deploy is at <commit>, expected <STACKS_SHA>." and exits 1 without calling any webhook

#### Scenario: No stacks SHA
- **WHEN** SHADOW_MODE is not true and STACKS_SHA is empty
- **THEN** the stage exits 1 without calling any webhook, because it cannot confirm what `refs/heads/deploy` should be

## ADDED Requirements

### Requirement: Local Manifest Source
The module SHALL read the manifest from the local file `stacks/stacks.yaml` at the repository root (the `stacks` submodule checkout), or from `stacks_manifest_path` when set, and SHALL NOT fetch it over the network. A missing or unparsable manifest file SHALL fail planning. The module and terraform/portainer-root SHALL NOT declare `stacks_sha`, `stacks_manifest_url` or `stacks_manifest_token`.

#### Scenario: Pinned manifest from the checkout
- **WHEN** portainer-apply runs with STACKS_SHA set
- **THEN** the managed stack set comes from `stacks/stacks.yaml` as checked out at STACKS_SHA
- **AND** no HTTP request is made to fetch the manifest

#### Scenario: Manifest file missing
- **WHEN** `stacks/stacks.yaml` does not exist, for example because the submodule is not initialized
- **THEN** planning fails with an error and no saved plan is produced

#### Scenario: Unparsable manifest
- **WHEN** the manifest file is not valid YAML
- **THEN** planning fails with an error and no saved plan is produced

#### Scenario: Removed manifest inputs
- **WHEN** an operator passes `-var stacks_sha=<sha>`, `-var stacks_manifest_url=<url>` or `-var stacks_manifest_token=<token>` to terraform/portainer-root
- **THEN** Terraform rejects the value as an undeclared variable

#### Scenario: Manifest path override
- **WHEN** `stacks_manifest_path` is set to an existing local file
- **THEN** the module reads the manifest from that file instead of `stacks/stacks.yaml`

### Requirement: Manifest Plan Guards
The module SHALL fail planning, not warn, when the manifest `version` is not 1, when it yields no Portainer-managed stack, when a managed stack has a blank `compose_path`, or when a managed stack has no entry in `local.portainer_stack_envs`. The guards SHALL be evaluated even when the managed set is empty, so a failing guard leaves no saved plan and nothing is applied.

#### Scenario: Error body parsed as a manifest
- **WHEN** the manifest file parses as YAML but has no `stacks` key, for example content `404: Not Found`
- **THEN** planning fails with "stacks.yaml defines no portainer_managed stacks."
- **AND** no `portainer_stack` or `WEBHOOK_URL_*` Infisical secret is destroyed

#### Scenario: Wrong manifest version
- **WHEN** stacks.yaml has `version: 2`
- **THEN** planning fails with "stacks.yaml must define version: 1."

#### Scenario: Blank compose path
- **WHEN** a managed stack has `compose_path: ""`
- **THEN** planning fails with "All portainer_managed stacks in stacks.yaml must define a non-empty compose_path."

#### Scenario: Missing env map
- **WHEN** a managed stack has no entry in `local.portainer_stack_envs`
- **THEN** planning fails with "Every Portainer-managed stack in stacks.yaml must have a corresponding env map in local.portainer_stack_envs."

#### Scenario: One stack removed
- **WHEN** one managed stack is removed from stacks.yaml and at least one managed stack remains
- **THEN** the guards pass and the plan destroys only that stack's `portainer_stack` and `WEBHOOK_URL_<NAME>` secret

### Requirement: Deploy Reference Advancement
When STACKS_SHA is set, the stacks-deploy-ref stage SHALL set `refs/heads/deploy` in JoseStud/stacks to STACKS_SHA, creating the ref if absent and moving it backwards if needed, using a write-scoped GitHub credential read from Infisical that it SHALL NOT print. It SHALL fail when the credential is missing or rejected or the ref does not read back as STACKS_SHA.

#### Scenario: Trusted SHA bump
- **WHEN** `refs/heads/deploy` is at commit A and STACKS_SHA is B
- **THEN** the stage moves the ref to B, prints "refs/heads/deploy: <A> -> <B>" and succeeds after reading back B

#### Scenario: Already current
- **WHEN** `refs/heads/deploy` already resolves to STACKS_SHA
- **THEN** the stage writes nothing and prints that the ref is already at STACKS_SHA

#### Scenario: Reference absent
- **WHEN** JoseStud/stacks has no `refs/heads/deploy`
- **THEN** the stage creates it at STACKS_SHA

#### Scenario: Gitlink rollback
- **WHEN** the infra repo reverts the `stacks` gitlink so that STACKS_SHA is an ancestor of the commit `refs/heads/deploy` holds
- **THEN** the stage moves the ref back to STACKS_SHA

#### Scenario: Shadow mode
- **WHEN** SHADOW_MODE is true
- **THEN** the stage obtains the credential and reads the current ref, prints the move it would make, writes nothing and exits 0

#### Scenario: Credential missing or rejected
- **WHEN** the credential is absent from Infisical, or GitHub rejects the update with HTTP 401, 403, 404 or 422
- **THEN** the stage exits 1 with a message that names the HTTP status but not the credential, and `refs/heads/deploy` is unchanged

#### Scenario: No stacks SHA
- **WHEN** STACKS_SHA is empty
- **THEN** the stage prints "stacks-deploy-ref: skipped (no stacks_sha)" and does not contact GitHub

#### Scenario: Untrusted SHA
- **WHEN** stacks-sha-trust fails for STACKS_SHA
- **THEN** stacks-deploy-ref does not run and `refs/heads/deploy` is unchanged

## REMOVED Requirements

### Requirement: Manifest Source Resolution
**Reason**: Fetching `stacks.yaml` over HTTP from a URL derived from `stacks_sha` broke silently on non-2xx responses, because hashicorp/http 3.x does not check status codes. Local Manifest Source replaces it with a read of the pinned local checkout, so the GitHub URL derivation, the bearer-token header and the `stacks_sha` format validation all go away.
**Migration**: CI needs no action, since the orchestrator checks the submodule out at STACKS_SHA. A local or break-glass operator puts the `stacks` submodule at the intended commit before planning (for example `git -C stacks fetch origin deploy && git -C stacks checkout FETCH_HEAD`) and stops passing `stacks_sha`, `stacks_manifest_url` or `stacks_manifest_token`. Delete any `goodoldme-portainer` workspace variables with those names. The workspace runs with local operations, so such variables are already unused.

### Requirement: Advisory Manifest Checks
**Reason**: Warning-only `check` blocks let a broken or empty manifest produce a plan that destroys every stack. Manifest Plan Guards replaces them with plan-time failures. The `stacks_sha_requires_github_repository_url` check goes away because the module no longer derives a GitHub raw URL.
**Migration**: No operator action. A manifest that used to produce a warning (wrong `version`, blank `compose_path`, missing env map) now fails the plan, so fix `stacks.yaml` in JoseStud/stacks, or add the env map, before bumping the gitlink.
