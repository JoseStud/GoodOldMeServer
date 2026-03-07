# Infrastructure Orchestrator Cutover Checklist (Minimal)

Use this checklist before the first full run of `.github/workflows/infra-orchestrator.yml`.
For ownership context, see [Infisical Workflow](infisical-workflow.md#variable-ownership--mutability).

## 0) Auto-Managed Values (Do Not Set Manually)

These values are managed by automation after bootstrap and are not operator-owned configuration.

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| `/stacks/management/PORTAINER_ADMIN_PASSWORD_HASH` | Required | Platform | Rewritten on every bootstrap run from `PORTAINER_ADMIN_PASSWORD` (bcrypt). Do not set manually. | [ ] |
| `/management/PORTAINER_URL` | Required | Platform | Written after Portainer bootstrap. Do not set manually. | [ ] |
| `/management/PORTAINER_API_URL` | Required | Platform | Written after Portainer bootstrap. Do not set manually. | [ ] |
| `/management/PORTAINER_API_KEY` | Required | Platform | Repaired/rotated as needed during bootstrap. Do not set manually. | [ ] |
| `/deployments/PORTAINER_WEBHOOK_URLS` + `/deployments/WEBHOOK_URL_*` | Required | Platform | Rewritten by Portainer Terraform apply. Do not edit manually. | [ ] |
| `TF_VAR_network_access_policy` (TFC env var) | Required | Platform | Auto-updated by `.github/scripts/network/sync_network_access_policy.sh`. | [ ] |
| `/stacks/management/PORTAINER_AUTOMATION_ALLOWED_CIDRS` | Required | Security | Auto-synced from `network_access_policy.portainer_api.source_ranges`. | [ ] |

## 1) Infra Repo: GitHub Actions Variables (`vars.*`)

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| `INFISICAL_MACHINE_IDENTITY_ID` | Required | Security | OIDC machine identity used for Infisical login in workflows. | [ ] |
| `INFISICAL_PROJECT_ID` | Required | Platform | Shared project ID for Terraform/Ansible/automation reads. | [ ] |
| `INFISICAL_SSH_CA_ID` | Required | Security | SSH CA identifier for ephemeral cert signing in pipeline. | [ ] |
| `TFC_ORGANIZATION` (or `TFC_ORG`) | Required | Platform | Terraform Cloud organization slug. | [ ] |
| `CLOUD_STATIC_RUNNER_LABEL` | Required | Platform | Label for deterministic static-egress cloud runner. | [ ] |
| `TFC_WORKSPACE_INFRA` | Optional | Platform | Defaults to `goodoldme-infra` when unset. | [ ] |
| `TFC_WORKSPACE_PORTAINER` | Optional | Platform | Defaults to `goodoldme-portainer` when unset. | [ ] |
| `TFC_INFRA_APPLY_WAIT_TIMEOUT_SECONDS` | Optional | Operator | Defaults to `7200`. Manual confirm wait timeout. | [ ] |
| `STACKS_SHA_TRUST_WAIT_TIMEOUT_SECONDS` | Optional | Platform | Defaults to `900`. Wait timeout for stacks check completion on dispatch. | [ ] |
| `STACKS_SHA_TRUST_POLL_INTERVAL_SECONDS` | Optional | Platform | Defaults to `15`. Poll interval for stacks check completion on dispatch. | [ ] |

## 2) Infra Repo: GitHub Actions Secrets (`secrets.*`)

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| `TFC_TOKEN` | Required | Platform | Terraform Cloud API/team token with run and state output access. | [ ] |
| `INFISICAL_TOKEN` | Required | Security | Needed for the local `terraform/portainer-root` apply path. | [ ] |
| `INFISICAL_AGENT_CLIENT_ID` | Required | Security | Universal Auth client id used by the Ansible-managed host runtime sync and local webhook helper. | [ ] |
| `INFISICAL_AGENT_CLIENT_SECRET` | Required | Security | Universal Auth client secret used by the Ansible-managed host runtime sync and local webhook helper. | [ ] |
| `STACKS_REPO_READ_TOKEN` | Required | Security | Token used for trust verification of `stacks_sha` dispatch payloads. | [ ] |

## 3) Stacks Repo (Dispatch-Only Full Reconcile)

Required for `stacks/.github/workflows/stacks-dispatch-redeploy.yml` dispatching into this infra repo.

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| `vars.INFRA_REPO` | Optional | Platform | Optional when default `JoseStud/GoodOldMeServer` is correct. | [ ] |
| `secrets.INFRA_REPO_DISPATCH_TOKEN` | Required | Security | Fine-grained token used for repository dispatch to infra repo. | [ ] |
| `stacks/.github/workflows/stacks-ci.yml` active | Required | Platform | Stack compose validation and manifest sanity run in stacks repo. | [ ] |
| Dispatch payload schema `v5` implemented | Required | Platform | Must include only `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, and `reason=full-reconcile`. No selective stack/path fields remain. | [ ] |

Expected dispatch payload example:

```json
{
  "event_type": "stacks-redeploy-intent-v5",
  "client_payload": {
    "schema_version": "v5",
    "stacks_sha": "0123456789abcdef0123456789abcdef01234567",
    "source_sha": "0123456789abcdef0123456789abcdef01234567",
    "reason": "full-reconcile",
    "source_repo": "owner/stacks",
    "source_run_id": 123456789
  }
}
```

## 4) Terraform Cloud Workspace Variables

### Workspace: `goodoldme-infra` (`terraform/infra`)

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| `infisical_project_id` (Terraform var) | Required | Platform | Must match GitHub `INFISICAL_PROJECT_ID`. | [ ] |
| `TF_VAR_network_access_policy` (env var JSON) | Required | Security | `oci_ssh.source_ranges` IPv4 only, `gcp_ssh.source_ranges` IPv6 only, `portainer_api.source_ranges` dual-stack allowed. | [ ] |
| Infisical provider auth variables | Required | Security | For example `INFISICAL_TOKEN` in attached variable set. | [ ] |
| OCI provider auth (`auth = "SecurityToken"`) | Required | Security | Ensure workspace has valid OCI auth variables. | [ ] |
| GCP provider auth | Required | Security | For example `GOOGLE_CREDENTIALS`. | [ ] |
| Workspace Auto Apply disabled | Required | Platform | Infrastructure Orchestrator waits for manual confirm/apply in Terraform Cloud. | [ ] |

### Workspace: `goodoldme-portainer` (`terraform/portainer-root`)

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| `infisical_project_id` (Terraform var) | Required | Platform | Must match GitHub `INFISICAL_PROJECT_ID`. | [ ] |
| `portainer_endpoint_id` | Optional | Platform | Defaults to `1` when omitted. | [ ] |
| `repository_url` / `repository_reference` | Optional | Platform | Needed only for non-default git source/ref. | [ ] |
| `git_username` / `git_password` | Optional | Security | Needed only for private stacks repo auth. | [ ] |
| `stacks_manifest_url` / `stacks_manifest_token` | Optional | Security | Needed only for private manifest endpoint. | [ ] |
| Infisical provider auth variables | Required | Security | For example `INFISICAL_TOKEN`. | [ ] |
| Terraform execution can reach `PORTAINER_API_URL` | Required | Platform | Validate reachability before apply. | [ ] |
| Workspace `operations=false` | Required | Platform | Portainer workspace runs local Terraform CLI apply path. | [ ] |

## 5) New Observability Secrets (Infisical)

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| `/stacks/observability/ALERTMANAGER_WEBHOOK_URL` | Required | Operator | Slack/Discord webhook URL for alert notifications. | [ ] |

## 6) First Dry-Run and First Full Run

| Item | Requirement | Owner | Notes | Checkbox |
|------|-------------|-------|-------|----------|
| Run `validate-planner-contracts.yml`, `validate-terraform.yml`, and `validate-ansible.yml` and confirm their key jobs pass | Required | Operator | Use each workflow's manual button or let PR/push automation run them before the first orchestrator execution. | [ ] |
| Verify `stacks-ci.yml` passes in stacks repo | Required | Platform | Repo-level validation must pass before dispatching the full reconcile. | [ ] |
| Verify cloud runner deterministic dual-stack egress | Required | Platform | `curl -4 https://api.ipify.org` and `curl -6 https://api64.ipify.org` from runner. | [ ] |
| Merge a representative infra change to `main` | Required | Operator | A change under `terraform/infra`, `terraform/oci`, or `terraform/gcp` should trigger `infra-orchestrator.yml` automatically and start the infra run sequence. | [ ] |
| Confirm/apply infra run in Terraform Cloud UI when prompted | Required | Operator | Required because Auto Apply is disabled. | [ ] |
| Confirm dispatch path validates `schema_version=v5` and waits for trusted `stacks_sha` checks | Required | Platform | `stacks-sha-trust` should pass before stack SHA is consumed by later stages, including host sync and config sync. | [ ] |
| Retire legacy workflow checks and runbooks | Required | Platform | Remove old `IaC Validation` / `Meta Pipeline` checks, stop using retired workflow entry points, and standardize on the active workflow set in [Workflow Lifecycle](workflow-lifecycle.md). | [ ] |
| Ensure CI governance checks are required | Required | Platform | Include `Lint GitHub Actions / lint`, `Validate Planner Contracts / workflow-contracts`, `Validate Terraform / tfc-speculative-plan`, and `Validate Ansible / ansible-validate` in required PR checks. | [ ] |
