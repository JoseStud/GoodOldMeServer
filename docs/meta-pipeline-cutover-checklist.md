# Meta Pipeline Cutover Checklist (Minimal)

Use this checklist before the first full run of `.github/workflows/meta-pipeline.yml`.

## 1) Infra Repo: GitHub Actions Variables (`vars.*`)

- [ ] `INFISICAL_MACHINE_IDENTITY_ID`
- [ ] `INFISICAL_PROJECT_ID`
- [ ] `INFISICAL_SSH_CA_ID`
- [ ] `TFC_ORGANIZATION` (or `TFC_ORG`)

Optional but recommended:

- [ ] `TFC_WORKSPACE_INFRA` (defaults to `goodoldme-infra`)
- [ ] `TFC_WORKSPACE_PORTAINER` (defaults to `goodoldme-portainer`)
- [ ] `TFC_INFRA_APPLY_WAIT_TIMEOUT_SECONDS` (defaults to `7200`)

## 2) Infra Repo: GitHub Actions Secrets (`secrets.*`)

- [ ] `TFC_TOKEN` (Terraform Cloud API/team token with run + state output access)

## 3) Stacks Repo (Only for cross-repo auto-dispatch)

Required for `stacks/.github/workflows/private-redeploy.yml` dispatching into this repo:

- [ ] `vars.INFRA_REPO` (optional if default `JoseStud/GoodOldMeServer` is correct)
- [ ] `secrets.INFRA_REPO_DISPATCH_TOKEN`

## 4) Terraform Cloud Workspace Variables

### Workspace: `goodoldme-infra` (`terraform/infra`)

Terraform variables:

- [ ] `infisical_project_id` (string; same value as `INFISICAL_PROJECT_ID`)
- [ ] `oci_ssh_allowed_cidr` (string CIDR, for example `203.0.113.10/32`)
- [ ] `gcp_ssh_allowed_cidrs` (list(string), for example `["203.0.113.10/32","2001:db8::/64"]`)

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

## 5) First Dry-Run and First Full Run

- [ ] Run `.github/workflows/meta-pipeline-smoke.yml` (workflow_dispatch) and verify payload/context outputs.
- [ ] Run `.github/workflows/meta-pipeline.yml` with `run_infra_apply=true`.
- [ ] Confirm/apply the created infra run in Terraform Cloud UI when prompted.
- [ ] Verify downstream jobs proceed only after infra run reaches `applied` (or no-change completion).
