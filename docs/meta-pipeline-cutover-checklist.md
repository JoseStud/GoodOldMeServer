# Meta Pipeline Cutover Checklist (Minimal)

Use this checklist before the first full run of `.github/workflows/meta-pipeline.yml`.
For full ownership context, see [Infisical Workflow](infisical-workflow.md#variable-ownership--mutability).

## 0) Auto-Managed Values (Do Not Set Manually)

These values are managed by automation after bootstrap and should not be treated as operator-owned configuration.

| Variable / Path | Managed By | Notes |
|-----------------|------------|-------|
| `/stacks/management/PORTAINER_ADMIN_PASSWORD_HASH` | Ansible `portainer_bootstrap` | Rewritten on every bootstrap run from `PORTAINER_ADMIN_PASSWORD` (`bcrypt`) |
| `/management/PORTAINER_URL` | Ansible `portainer_bootstrap` | Written after Portainer bootstrap |
| `/management/PORTAINER_API_URL` | Ansible `portainer_bootstrap` | Written after Portainer bootstrap |
| `/management/PORTAINER_API_KEY` | Ansible `portainer_bootstrap` | Repaired/rotated as needed during bootstrap |
| `/deployments/PORTAINER_WEBHOOK_URLS` + `/deployments/WEBHOOK_URL_*` | Terraform `terraform/portainer-root` | Rewritten by Portainer Terraform apply |
| `TF_VAR_network_access_policy` (TFC env var) | `.github/scripts/sync_network_access_policy.sh` | Meta pipeline updates it from runner egress policy |
| `/stacks/management/PORTAINER_AUTOMATION_ALLOWED_CIDRS` | `.github/scripts/sync_network_access_policy.sh` | Auto-synced from `network_access_policy.portainer_api.source_ranges` |

## 1) Infra Repo: GitHub Actions Variables (`vars.*`)

- [ ] `INFISICAL_MACHINE_IDENTITY_ID`
- [ ] `INFISICAL_PROJECT_ID`
- [ ] `INFISICAL_SSH_CA_ID`
- [ ] `TFC_ORGANIZATION` (or `TFC_ORG`)
- [ ] `CLOUD_STATIC_RUNNER_LABEL` (label for deterministic static-egress cloud runner)

Optional but recommended:

- [ ] `TFC_WORKSPACE_INFRA` (defaults to `goodoldme-infra`)
- [ ] `TFC_WORKSPACE_PORTAINER` (defaults to `goodoldme-portainer`)
- [ ] `TFC_INFRA_APPLY_WAIT_TIMEOUT_SECONDS` (defaults to `7200`)

## 2) Infra Repo: GitHub Actions Secrets (`secrets.*`)

- [ ] `TFC_TOKEN` (Terraform Cloud API/team token with run + state output access)
- [ ] `INFISICAL_TOKEN` (required for local `terraform/portainer-root` apply path)

## 3) Stacks Repo (Only for cross-repo auto-dispatch)

Required for `stacks/.github/workflows/private-redeploy.yml` dispatching into this repo:

- [ ] `vars.INFRA_REPO` (optional if default `JoseStud/GoodOldMeServer` is correct)
- [ ] `secrets.INFRA_REPO_DISPATCH_TOKEN`

## 4) Terraform Cloud Workspace Variables

### Workspace: `goodoldme-infra` (`terraform/infra`)

Terraform variables:

- [ ] `infisical_project_id` (string; same value as `INFISICAL_PROJECT_ID`)
- [ ] `TF_VAR_network_access_policy` (env var, JSON object; auto-created/updated by meta-pipeline network policy sync)
  - `oci_ssh.source_ranges` must be IPv4 CIDRs
  - `gcp_ssh.source_ranges` must be IPv6 CIDRs
  - `portainer_api.source_ranges` may include both IPv4/IPv6 CIDRs

Provider/auth environment variables (attach your existing variable set):

- [ ] Infisical provider auth (for example `INFISICAL_TOKEN`)
- [ ] OCI provider auth for `auth = "SecurityToken"` mode
- [ ] GCP provider auth (for example `GOOGLE_CREDENTIALS`)

Workspace setting:

- [ ] Auto Apply is **disabled** (meta-pipeline now waits for manual confirm/apply in Terraform Cloud)

### Workspace: `goodoldme-portainer` (`terraform/portainer-root`)

Terraform variables:

- [ ] `infisical_project_id` (string; same value as `INFISICAL_PROJECT_ID`)

Optional Terraform variables:

- [ ] `portainer_endpoint_id` (default `1`)
- [ ] `repository_url` / `repository_reference`
- [ ] `git_username` / `git_password` (private stacks repo only)
- [ ] `stacks_manifest_url` / `stacks_manifest_token` (private manifest only)

Provider/runtime requirements:

- [ ] Infisical provider auth (for example `INFISICAL_TOKEN`)
- [ ] Terraform execution environment can reach `PORTAINER_API_URL`
- [ ] Workspace `operations=false` (local Terraform CLI apply; not remote TFC apply)

## 5) New Observability Secrets (Infisical)

- [ ] `ALERTMANAGER_WEBHOOK_URL` — Slack/Discord webhook URL for alert notifications (under `/stacks/observability`)

## 6) First Dry-Run and First Full Run

- [ ] Run `.github/workflows/meta-pipeline-smoke.yml` (workflow_dispatch) and verify payload/context outputs.
- [ ] Verify the `compose-validate` job passes in `.github/workflows/iac-validation.yml` for all stack files.
- [ ] Verify cloud runner has deterministic dual-stack egress (`curl -4 https://api.ipify.org`, `curl -6 https://api64.ipify.org`).
- [ ] Run `.github/workflows/meta-pipeline.yml` with `run_infra_apply=true`.
- [ ] Confirm/apply the created infra run in Terraform Cloud UI when prompted.
- [ ] Verify downstream jobs proceed only after infra run reaches `applied` (or no-change completion).
