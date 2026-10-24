# ci-pipeline-orchestration Specification

## Purpose
Run the infra repository's deployment pipeline end to end. `.github/workflows/orchestrator.yml` chains `compute-context`, the Terraform Cloud `infra-apply` job and the Tailscale-connected `dagger-pipeline` job. The pipeline job runs `ci/src/ci_pipeline/__main__.py`, which orders and gates the containerized and host-subprocess stages from the computed run-toggles.

## Requirements

### Requirement: Orchestrator Triggers And Concurrency
The orchestrator workflow SHALL run on pushes to `main` that touch `terraform/**`, `stacks`, `.gitmodules`, `ansible/**` or `.ansible-lint`, and on `workflow_dispatch` with boolean inputs `ansible_only`, `force_health_redeploy` and `skip_ansible_bootstrap` (each defaulting to `false`). All runs SHALL share concurrency group `infra-orchestrator-<ref>` with `cancel-in-progress: true`.

#### Scenario: Push outside the trigger paths
- **WHEN** a push to `main` changes only files outside the trigger paths, for example only `docs/**` or `.github/**`
- **THEN** the orchestrator workflow is not started

#### Scenario: Newer run supersedes an in-flight run
- **WHEN** an orchestrator run starts while an earlier run for the same ref is still in progress
- **THEN** GitHub cancels the earlier run
- **AND** the group suffix is `github.ref_name`, falling back to the repository default branch and then to `main`

#### Scenario: Workflow token permissions
- **WHEN** any orchestrator job runs
- **THEN** the workflow token has `id-token: write` and `contents: read`

### Requirement: Job Graph Gating
The workflow SHALL run `compute-context`, then `infra-apply` only when `run_infra_apply` is `true`, then `dagger-pipeline` only when the run is not cancelled, `compute-context` succeeded, `has_work` is `true`, and `infra-apply` succeeded or was skipped. `dagger-pipeline` SHALL receive the context outputs as `RUN_*`, `HAS_WORK`, `STACKS_SHA`, `ANSIBLE_TAGS` and `REASON` environment variables.

#### Scenario: Ansible-only push
- **WHEN** `compute-context` emits `run_infra_apply=false` and `has_work=true`
- **THEN** `infra-apply` is skipped and `dagger-pipeline` still runs

#### Scenario: Infra apply fails
- **WHEN** `infra-apply` fails
- **THEN** `dagger-pipeline` does not run

#### Scenario: No work
- **WHEN** `compute-context` emits `has_work=false`
- **THEN** both `infra-apply` and `dagger-pipeline` are skipped
- **AND** if the pipeline is started with `HAS_WORK` other than `true`, it prints `pipeline: no work to do (HAS_WORK=false)` and exits 0 without opening a Dagger connection

### Requirement: Terraform Cloud Infra Apply
The `infra-apply` job SHALL upload the `terraform` directory to Terraform Cloud workspace `TFC_WORKSPACE_INFRA` (default `goodoldme-infra`) with `hashicorp/tfc-workflows-github` `upload-configuration@v1.3.2`, create a run on that configuration version with `create-run@v1.3.2`, and then block in `.github/scripts/stages/infra_apply.sh` until the run completes. The job SHALL NOT connect to the tailnet.

#### Scenario: Run creation
- **WHEN** `infra-apply` runs
- **THEN** it creates the run with message `Infrastructure orchestrator infra apply (<reason>)`, using organization `vars.TFC_ORGANIZATION` (falling back to `vars.TFC_ORG`) and token `secrets.TFC_TOKEN`
- **AND** the job runs in environment `Jux` with a 150-minute timeout, after installing pinned jq via `./.github/actions/bootstrap-query-tools` and Terraform via `hashicorp/setup-terraform@v4`

#### Scenario: Wait parameters
- **WHEN** `infra_apply.sh` runs
- **THEN** it requires `RUN_ID` and `TFC_WORKSPACE` and calls `.github/scripts/tfc/wait_for_tfc_run.sh` with `REQUIRE_MANUAL_CONFIRM=true`, `FAIL_IF_AUTO_APPLY=true`, `SUCCESS_STATUSES=planned_and_finished,applied` and `TERMINAL_FAILURE_STATUSES=errored,canceled,discarded,force_canceled`
- **AND** `WAIT_TIMEOUT_SECONDS` comes from `vars.TFC_INFRA_APPLY_WAIT_TIMEOUT_SECONDS` (default `7200`) and `POLL_INTERVAL_SECONDS` from `vars.TFC_PLAN_POLL_INTERVAL_SECONDS` (default `10`)

### Requirement: Terraform Cloud Run Wait
`wait_for_tfc_run.sh` SHALL poll `GET <TFC_API_URL>/runs/<RUN_ID>` (default `https://app.terraform.io/api/v2`) every `POLL_INTERVAL_SECONDS` until `WAIT_TIMEOUT_SECONDS` pass. With manual confirmation required, it SHALL exit 0 only on status `applied`, or on `planned_and_finished` with `has-changes` false and the run not confirmable. It MUST exit 1 on a terminal failure status, a failed query, auto-apply, or timeout.

#### Scenario: Operator confirms the apply
- **WHEN** the run becomes confirmable before any apply status (`apply_queued`, `applying`, `applied`) is seen
- **THEN** the script prints `Run is confirmable. Confirm and apply in Terraform Cloud to continue.` once
- **AND** it exits 0 when the status reaches `applied`

#### Scenario: Plan with no changes
- **WHEN** the run reaches `planned_and_finished` with `is-confirmable` false and `has-changes` false
- **THEN** the script exits 0 reporting that the run completed with no changes

#### Scenario: Auto-apply workspace
- **WHEN** the first polled status outside the success statuses comes with `auto-apply` true
- **THEN** the script exits 1 and tells the operator to disable auto-apply for the workspace

#### Scenario: Failure, query error or timeout
- **WHEN** the status becomes `errored`, `canceled`, `discarded` or `force_canceled`, a run query fails, or the deadline passes
- **THEN** the script exits 1, printing `Timed out after <N>s waiting for run ...` in the timeout case
- **AND** a `WAIT_TIMEOUT_SECONDS` or `POLL_INTERVAL_SECONDS` that is not a positive integer makes it exit 1 before polling

### Requirement: Runner Tailnet And SOCKS5 Proxy
Before running the pipeline, the `dagger-pipeline` job SHALL join the tailnet with `tailscale/github-action@v4` as tag `tag:ci`, start `pproxy` as a SOCKS5 server on `127.0.0.1:1055` and wait up to 10 seconds for it to listen, and delete `/etc/hosts` lines that start with `::1` so that `localhost` resolves to `127.0.0.1`.

#### Scenario: Proxy comes up
- **WHEN** `pproxy` accepts connections on `127.0.0.1:1055` within 10 seconds
- **THEN** the step logs `SOCKS5 proxy listening on 127.0.0.1:1055` and the job continues

#### Scenario: Proxy does not come up
- **WHEN** nothing listens on `127.0.0.1:1055` within 10 seconds
- **THEN** the proxy step fails and the pipeline is not run

#### Scenario: Runner toolchain
- **WHEN** the job prepares the runner
- **THEN** it checks out with `fetch-depth: 0` and recursive submodules, authenticates Tailscale with `vars.TS_OAUTH_CLIENT_ID` and `secrets.TS_OAUTH_SECRET`, installs Dagger via `dagger/dagger-for-github@v7`, the Infisical CLI from its apt repository, `pip install ./ci`, `ansible-core==<vars.ANSIBLE_CORE_VERSION or 2.20.2>` and `passlib[bcrypt]`
- **AND** it runs `dagger run python -m ci_pipeline` in environment `Jux` with a 120-minute job timeout

### Requirement: Dagger Proxy Binding
The pipeline SHALL expose runner TCP port 1055 to containers as a Dagger host service bound under hostname `tailscale-proxy`, and SHALL set `ALL_PROXY=socks5://tailscale-proxy:1055`, `SSH_PROXY_HOST=tailscale-proxy`, `SSH_PROXY_PORT=1055` and a fixed `NO_PROXY` list in every containerized stage except stacks-sha-trust and cloudflare-dns-sync, which get no proxy.

#### Scenario: Public domains bypass the proxy
- **WHEN** a stage container is bound to the proxy
- **THEN** `NO_PROXY` is `github.com,githubusercontent.com,infisical.com,docker.io,docker.com,alpinelinux.org,terraform.io,hashicorp.com,dagger.cloud,ipify.org,goodold.me`

#### Scenario: Binding is created without probing
- **WHEN** the pipeline opens its Dagger connection
- **THEN** it defines the host service without checking whether port 1055 is listening and logs `pipeline: tailscale SOCKS5 proxy bound`

#### Scenario: Public-API stages run unproxied
- **WHEN** stacks-sha-trust or cloudflare-dns-sync runs
- **THEN** its container has no `tailscale-proxy` service binding and none of the proxy environment variables

### Requirement: Stage Layering
`ci_pipeline` SHALL run enabled stages in this order: stacks-sha-trust and secret-validation concurrently; then cloudflare-dns-sync, concurrently with network-policy-sync when that runs; then the Ansible bootstrap or host-sync subprocess; then post-bootstrap-secret-check, config-sync, portainer-api-preflight, portainer-apply-debug, portainer-apply and health-gated-redeploy, one at a time; and network-policy-revoke-ssh last.

#### Scenario: Full-run push
- **WHEN** `RUN_INFRA_APPLY`, `RUN_ANSIBLE_BOOTSTRAP` and `RUN_PORTAINER_APPLY` are `true` and the other toggles are `false`
- **THEN** the stages run as stacks-sha-trust with secret-validation, network-policy-sync with cloudflare-dns-sync, Ansible bootstrap, post-bootstrap-secret-check, portainer-api-preflight, portainer-apply-debug, portainer-apply, network-policy-revoke-ssh
- **AND** the pipeline logs `pipeline: complete`

#### Scenario: Stacks SHA bump
- **WHEN** `RUN_PORTAINER_APPLY`, `RUN_HOST_SYNC`, `RUN_CONFIG_SYNC` and `RUN_HEALTH_REDEPLOY` are `true` and `RUN_INFRA_APPLY` and `RUN_ANSIBLE_BOOTSTRAP` are `false`
- **THEN** cloudflare-dns-sync runs alone in its layer, with the log `network-policy-sync: skipped (tailscale-first run, no infra/bootstrap SSH policy mutation)`, followed by host-sync, post-bootstrap-secret-check, config-sync, portainer-api-preflight, portainer-apply-debug, portainer-apply and health-gated-redeploy
- **AND** revoke is skipped with the log `network-policy-revoke-ssh: skipped (no SSH policy sync was applied)`

#### Scenario: Network policy handover to the Portainer preflight
- **WHEN** network-policy-sync runs
- **THEN** the `network_access_policy_json` value it writes to its in-container `GITHUB_OUTPUT` file (`/tmp/github_output`) is passed to portainer-api-preflight as `NETWORK_ACCESS_POLICY_JSON`
- **AND** when network-policy-sync does not run, the value passed is `{"oci_ssh":{"enabled":false,"source_ranges":[]}}`

### Requirement: Stage Run Conditions
Each stage SHALL run only under its gate: stacks-sha-trust when `STACKS_SHA` is non-empty; secret-validation when any run toggle other than `RUN_CONFIG_SYNC` is set; network-policy-sync and network-policy-revoke-ssh on `RUN_INFRA_APPLY` or `RUN_ANSIBLE_BOOTSTRAP`; cloudflare-dns-sync always; post-bootstrap-secret-check, portainer-apply-debug and portainer-apply on `RUN_PORTAINER_APPLY`; portainer-api-preflight on that or `RUN_HEALTH_REDEPLOY`; health-gated-redeploy on `RUN_HEALTH_REDEPLOY`.

#### Scenario: Toggle parsing
- **WHEN** a `RUN_*` or `HAS_WORK` variable is unset, or holds anything other than `true` in any letter case
- **THEN** the pipeline treats it as false

#### Scenario: Narrow Portainer retry
- **WHEN** a dispatch with `ansible_only=true` and `skip_ansible_bootstrap=true` gives `RUN_PORTAINER_APPLY=true` and every other toggle `false`
- **THEN** no inventory is rendered and network-policy-sync, Ansible, health-gated-redeploy and network-policy-revoke-ssh do not run
- **AND** stacks-sha-trust, secret-validation, cloudflare-dns-sync, post-bootstrap-secret-check, portainer-api-preflight, portainer-apply-debug and portainer-apply run

#### Scenario: Skipped preflight logging
- **WHEN** `STACKS_SHA` is empty, or none of the toggles that secret-validation checks is set
- **THEN** the pipeline logs `stacks-sha-trust: skipped (no stacks_sha)` or `secret-validation: skipped (no stages enabled)` and continues

### Requirement: Ansible Host Subprocess Stages
Ansible stages SHALL run on the runner (not in a Dagger container) as `bash .github/scripts/stages/ansible_run.sh`, with the runner environment plus `INVENTORY_FILE=inventory-ci.yml` and, when non-empty, `STACKS_SHA` and `ANSIBLE_TAGS`. Bootstrap or host-sync SHALL run when `RUN_ANSIBLE_BOOTSTRAP` or `RUN_HOST_SYNC` is true. Config-sync SHALL run with tags `sync-configs` when `RUN_CONFIG_SYNC` is true.

#### Scenario: Bootstrap uses computed tags
- **WHEN** `RUN_ANSIBLE_BOOTSTRAP` is `true`
- **THEN** the Ansible run uses the `ANSIBLE_TAGS` value emitted by `compute-context`, so an empty value means no tag filter

#### Scenario: Host-sync without bootstrap
- **WHEN** `RUN_HOST_SYNC` is `true` and `RUN_ANSIBLE_BOOTSTRAP` is `false`
- **THEN** the Ansible run uses `ANSIBLE_TAGS=phase7_runtime_sync`

#### Scenario: Stacks SHA bump runs Ansible twice
- **WHEN** both `RUN_HOST_SYNC` and `RUN_CONFIG_SYNC` are `true`
- **THEN** `ansible_run.sh` runs once with tags `phase7_runtime_sync` after cloudflare-dns-sync, and again with tags `sync-configs` after post-bootstrap-secret-check and before portainer-api-preflight
- **AND** the inventory is exported to `inventory-ci.yml` before each run

### Requirement: Inventory Handover
When `RUN_ANSIBLE_BOOTSTRAP`, `RUN_HOST_SYNC` or `RUN_CONFIG_SYNC` is true, the pipeline SHALL define a `base` container that runs `.github/scripts/tfc/render_inventory_from_tfc_outputs.sh <TFC_WORKSPACE_INFRA> inventory-ci.yml` (workspace default `goodoldme-infra`), and SHALL export the rendered file to `inventory-ci.yml` on the runner before each Ansible run. The render only executes when the file is exported.

#### Scenario: Inventory rendered from Terraform Cloud outputs
- **WHEN** the workspace's current state version has outputs `oci_public_ips` and `gcp_witness_tailscale_hostname`
- **THEN** the inventory lists hosts `oci-node-1` to `oci-node-N`, one per IP in order, with `ansible_user: "ubuntu"` in group `oci_nodes`
- **AND** it lists host `gcp-witness`, whose `ansible_host` is the witness hostname, with `ansible_user: "debian"` in group `gcp_witness`

#### Scenario: Missing outputs
- **WHEN** the workspace id cannot be resolved, the state has no outputs link, `oci_public_ips` is missing or empty, or `gcp_witness_tailscale_hostname` is missing
- **THEN** the render script exits non-zero, so the export fails before any Ansible stage starts
- **AND** this happens after the layer-2 stages (cloudflare-dns-sync and, when enabled, network-policy-sync) have already run

#### Scenario: Inventory not needed
- **WHEN** `RUN_ANSIBLE_BOOTSTRAP`, `RUN_HOST_SYNC` and `RUN_CONFIG_SYNC` are all `false`
- **THEN** no inventory container is defined and `inventory-ci.yml` is not written

### Requirement: Stage Failure Semantics
A failing stage SHALL end the pipeline without starting any later stage, and the `Run Dagger pipeline` step SHALL fail. A Dagger `ExecError` SHALL be printed to stderr as `pipeline: stage failed — <error>` with exit status 1. A non-zero `ansible_run.sh` exit SHALL print `ansible-run: FAILED` to stderr and exit the pipeline with that script's exit status.

#### Scenario: Containerized stage fails
- **WHEN** a stage script exits non-zero inside its container, for example portainer-apply
- **THEN** the pipeline prints `pipeline: stage failed — <error>` to stderr and exits with status 1
- **AND** later stages, such as health-gated-redeploy, are not started

#### Scenario: One of two concurrent stages fails
- **WHEN** one of two concurrently awaited stages fails (stacks-sha-trust with secret-validation, or network-policy-sync with cloudflare-dns-sync)
- **THEN** its error ends the pipeline and no stage in a later layer starts

#### Scenario: Ansible subprocess fails
- **WHEN** `ansible_run.sh` exits with a non-zero status
- **THEN** the pipeline process exits with that same status and does not print the `pipeline: stage failed` message

### Requirement: Shadow Mode Propagation
`infra-apply` and `dagger-pipeline` SHALL set `SHADOW_MODE` from repository variable `vars.SHADOW_MODE` (default `false`). When it is `true`, `1` or `yes` (any case), `infra_apply.sh` SHALL exit 0 before polling Terraform Cloud. The pipeline SHALL still run every enabled stage and SHALL pass `SHADOW_MODE` (default `false`) to the network-policy-sync, network-policy-revoke-ssh, portainer-apply-debug, portainer-apply and health-gated-redeploy containers.

#### Scenario: Shadow infra apply
- **WHEN** `infra-apply` runs with `SHADOW_MODE=true`
- **THEN** the upload-configuration and create-run steps still run
- **AND** the wait step logs `SHADOW_MODE=true: skipping Terraform Cloud wait loop for run <RUN_ID>.` and succeeds, which lets `dagger-pipeline` proceed

#### Scenario: Shadow pipeline
- **WHEN** `dagger-pipeline` runs with `SHADOW_MODE=true`
- **THEN** the orchestration skips no stage because of it
- **AND** the value reaches the listed stage containers, and the Ansible subprocess through the inherited runner environment, which apply their own shadow handling

### Requirement: Containerized Stage Provisioning
Containerized stages SHALL mount the repository at `/work` as the working directory, excluding `.git`, `ci/.venv`, `ci/.pytest_cache` and `__pycache__`, and SHALL be built from profiles: `base` (`alpine:3.21` with bash, curl, git, coreutils, jq), `network` (base plus python3, netcat-openbsd, yq, Infisical CLI), `infisical` (base plus Infisical CLI), `terraform` (`hashicorp/terraform:latest` with bash, curl, git, jq, Infisical CLI) and `webhook` (network plus gomplate).

#### Scenario: Pinned query tools from the lock file
- **WHEN** `.github/ci/tool-versions.lock`, read from the pipeline's working directory, defines `JQ_VERSION`/`JQ_SHA256` and `YQ_VERSION`/`YQ_SHA256` (currently jq `1.7.1` and yq `4.52.1`)
- **THEN** jq is downloaded from `https://github.com/jqlang/jq/releases/download/jq-<version>/jq-linux-amd64` and yq from `https://github.com/mikefarah/yq/releases/download/v<version>/yq_linux_amd64`
- **AND** each binary is verified with `sha256sum -c`, and a checksum mismatch fails the container build

#### Scenario: Lock file or pin missing
- **WHEN** the lock file is absent, or a tool's version or checksum key is missing
- **THEN** that tool is installed unpinned with `apk add --no-cache jq` or `apk add --no-cache yq`
- **AND** requesting an unknown profile name raises a `ValueError`

#### Scenario: Stage profiles and credentials
- **WHEN** stages are built
- **THEN** stacks-sha-trust and inventory-handover use `base`; network-policy-sync, network-policy-revoke-ssh and cloudflare-dns-sync use `network`; secret-validation, post-bootstrap-secret-check and portainer-api-preflight (which also adds python3) use `infisical`; portainer-apply-debug and portainer-apply use `terraform`; health-gated-redeploy uses `webhook`
- **AND** credentials (`TFC_TOKEN`, `INFISICAL_TOKEN`, `INFISICAL_AGENT_CLIENT_ID`, `INFISICAL_AGENT_CLIENT_SECRET`, `GITHUB_TOKEN`, `STACKS_REPO_READ_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_URL`) are injected as Dagger secret variables, and only when they are non-empty on the runner
