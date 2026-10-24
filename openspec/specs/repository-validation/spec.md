# repository-validation Specification

## Purpose
Non-deploying CI checks for this repository: path-filtered pull_request and push validation of Terraform, Ansible, GitHub Actions YAML and the stacks gitlink, a weekly Ansible Galaxy freshness check, pinned tool bootstrapping from `.github/ci/tool-versions.lock`, and Dependabot update schedules. None of these workflows apply infrastructure changes.

## Requirements

### Requirement: Validation Workflow Triggers
Validate Terraform, Validate Ansible and Validate Planner Contracts SHALL run on `pull_request` and on `push` to any branch when a changed path matches the workflow's path filter. Lint GitHub Actions SHALL run on `pull_request` but on `push` only to `main`. Each of these four filters SHALL include `.github/ci/**`, `.github/actions/**`, `.github/workflows/**`, `stacks` and `.gitmodules`.

#### Scenario: Workflow change pushed to a feature branch
- **WHEN** a commit that changes only files under `.github/workflows/**` is pushed to a branch other than `main`
- **THEN** Validate Terraform, Validate Ansible and Validate Planner Contracts run for that push
- **AND** Lint GitHub Actions does not run for that push

#### Scenario: Workflow-specific path filters
- **WHEN** a pull request changes only `terraform/**`, only `ansible/**` or `.ansible-lint`, only top-level `scripts/**`, or only `docs/**`, `README.md` or `.github/dependabot.yml`
- **THEN** only Validate Terraform, only Validate Ansible, only Validate Planner Contracts, or only Lint GitHub Actions runs, respectively
- **AND** `.github/scripts/**` triggers the three validate workflows but not Lint GitHub Actions

#### Scenario: Stacks gitlink bump in a pull request
- **WHEN** a pull request changes the `stacks` gitlink or `.gitmodules`
- **THEN** Validate Terraform, Validate Ansible, Validate Planner Contracts and Lint GitHub Actions all run

### Requirement: Workflow Concurrency And Token Permissions
Validate Terraform, Validate Ansible, Validate Planner Contracts and Lint GitHub Actions SHALL use concurrency group `<workflow file base name>-<github.ref_name, else default branch, else main>` with `cancel-in-progress: true`; Check Ansible Galaxy Updates SHALL declare none. All five SHALL grant `contents: read`; the three validate workflows SHALL also grant `checks`, `statuses` and `pull-requests` read, and only Validate Terraform SHALL grant `id-token: write`.

#### Scenario: Superseded run on the same ref
- **WHEN** a new run of one of the four workflows starts for a ref while an earlier run of the same workflow for that ref is in progress
- **THEN** the earlier run is cancelled

#### Scenario: Pull request and push runs for the same branch
- **WHEN** the same branch produces both a `pull_request` run (ref name `<number>/merge`) and a `push` run (ref name `<branch>`)
- **THEN** the two runs fall in different concurrency groups and do not cancel each other

#### Scenario: Minimal token for lint and Galaxy check
- **WHEN** Lint GitHub Actions or Check Ansible Galaxy Updates runs
- **THEN** its `GITHUB_TOKEN` carries only `contents: read`

### Requirement: Terraform Format And Multi-Root Validation
Validate Terraform SHALL run `terraform fmt -check -recursive terraform`, and SHALL run `terraform init -backend=false -lockfile=readonly -input=false` followed by `terraform validate` for each of `terraform/infra`, `terraform/oci`, `terraform/gcp`, `terraform/portainer-root` and `terraform/portainer` as a matrix with `fail-fast: false`, using the Terraform CLI installed by `hashicorp/setup-terraform@v4` without a pinned version.

#### Scenario: Unformatted Terraform file
- **WHEN** any `.tf` file under `terraform/` is not in canonical `terraform fmt` format
- **THEN** the `terraform-fmt` job fails

#### Scenario: Provider lock not satisfiable
- **WHEN** a root's required providers cannot be satisfied from its committed `.terraform.lock.hcl`
- **THEN** `terraform init` fails for that root instead of updating the lock file
- **AND** the remaining matrix roots still run to completion

#### Scenario: No backend access during validation
- **WHEN** a root such as `terraform/portainer-root` declares a `backend "remote"` block
- **THEN** validation initializes it with `-backend=false` and uses no backend or Terraform Cloud credentials

### Requirement: Secret-Bearing Job Eligibility
The `tfc-speculative-plan` job of Validate Terraform and the `stacks-sha-trust` job of Validate Planner Contracts SHALL run only when `github.actor` is not `dependabot[bot]` and, for `pull_request` events, the head repository equals the base repository; both jobs SHALL run in the GitHub environment `Jux`.

#### Scenario: Dependabot change
- **WHEN** a run of either workflow is triggered with `github.actor` equal to `dependabot[bot]`
- **THEN** `tfc-speculative-plan` and `stacks-sha-trust` are skipped
- **AND** the remaining jobs of those workflows still run

#### Scenario: Pull request from a fork
- **WHEN** a pull request's head repository full name differs from the base repository
- **THEN** `tfc-speculative-plan` and `stacks-sha-trust` are skipped

#### Scenario: Same-repository push
- **WHEN** a non-Dependabot actor pushes matching changes to any branch of the repository
- **THEN** both jobs run in the `Jux` environment

### Requirement: Terraform Cloud Speculative Plan
After every `terraform-validate` matrix leg succeeds, `tfc-speculative-plan` SHALL resolve the workspace from `vars.TFC_WORKSPACE_INFRA` via `tfc_speculative_preflight.sh` with `WORKSPACE_KEY=infra`, upload the `terraform` directory as a speculative configuration version and create a `plan_only` run with `hashicorp/tfc-workflows-github` v1.3.2, then wait with `wait_for_tfc_run.sh`, succeeding only on run status `planned_and_finished` or `applied`.

#### Scenario: Missing Terraform Cloud inputs
- **WHEN** `secrets.TFC_TOKEN` is empty, neither `vars.TFC_ORGANIZATION` nor `vars.TFC_ORG` is set, or `vars.TFC_WORKSPACE_INFRA` is empty
- **THEN** the preflight step fails before any configuration is uploaded

#### Scenario: Speculative plan finishes
- **WHEN** the created run reaches status `planned_and_finished`
- **THEN** the job succeeds

#### Scenario: Plan failure or timeout
- **WHEN** the run reaches `errored`, `canceled`, `discarded` or `force_canceled`, a Terraform Cloud API query fails, or no success status is seen within `vars.TFC_PLAN_WAIT_TIMEOUT_SECONDS` (default `7200`) while polling every `vars.TFC_PLAN_POLL_INTERVAL_SECONDS` (default `10`)
- **THEN** the job fails

### Requirement: Pinned Ansible Tooling Installation
Validate Ansible SHALL install `ansible-core` and `ansible-lint` with pipx at `ANSIBLE_CORE_VERSION` and `ANSIBLE_LINT_VERSION` sourced from `.github/ci/tool-versions.lock`, fail if the installed tools report other versions, and install the collections in `ansible/requirements.yml` with `ansible-galaxy collection install --force-with-deps`, caching `~/.ansible/collections` under key `ansible-galaxy-<hashFiles('ansible/requirements.yml')>`.

#### Scenario: Installed version differs from the lock
- **WHEN** the first line of `ansible-playbook --version` does not contain `core <ANSIBLE_CORE_VERSION>` or the first line of `ansible-lint --version` does not contain `ansible-lint <ANSIBLE_LINT_VERSION>`
- **THEN** the install step fails and neither lint nor syntax check runs

#### Scenario: Galaxy cache key
- **WHEN** a cache entry for key `ansible-galaxy-<hash of ansible/requirements.yml>` is available to the run
- **THEN** `~/.ansible/collections` is restored from that entry before installation
- **AND** the collections are still installed from `ansible/requirements.yml` with `--force-with-deps`

### Requirement: Ansible Lint And Syntax Check
Validate Ansible SHALL run `ansible-lint -c .ansible-lint ansible`, applying profile `basic` and skipping `yaml[line-length]`, `name[template]`, `no-changed-when` and `var-naming[no-role-prefix]`, and SHALL run `ansible-playbook --syntax-check` on `ansible/playbooks/provision.yml` against a generated local inventory.

#### Scenario: Lint violation
- **WHEN** ansible-lint reports a violation under the `basic` profile that is not in the skip list
- **THEN** the `ansible-validate` job fails

#### Scenario: Syntax check inventory
- **WHEN** the syntax check runs
- **THEN** it uses `/tmp/ansible-syntax.ini`, which places `localhost` with `ansible_connection=local` in the groups `oci_nodes` and `gcp_witness`
- **AND** no remote host is contacted

### Requirement: Tool Version Lock File
`.github/ci/tool-versions.lock` SHALL hold `KEY=VALUE` shell assignments for `JQ_VERSION`, `JQ_SHA256`, `YQ_VERSION`, `YQ_SHA256`, `ANSIBLE_CORE_VERSION`, `ANSIBLE_LINT_VERSION`, `ACTIONLINT_VERSION` and `YAMLLINT_VERSION`, and the validation workflows and the bootstrap-query-tools action SHALL obtain these tool versions by sourcing that file rather than hard-coding them.

#### Scenario: Pin bump
- **WHEN** a value in `.github/ci/tool-versions.lock` changes
- **THEN** subsequent runs of the consuming validation jobs install the new pinned version
- **AND** a pull request containing the change triggers all four pull_request validation workflows through their `.github/ci/**` path filter

#### Scenario: Version string formats
- **WHEN** the bootstrap action builds download URLs and the lint workflow installs actionlint
- **THEN** the URLs are `https://github.com/jqlang/jq/releases/download/jq-<JQ_VERSION>/jq-linux-amd64` and `https://github.com/mikefarah/yq/releases/download/v<YQ_VERSION>/yq_linux_amd64`, so those values carry no leading `v`
- **AND** `ACTIONLINT_VERSION` is passed verbatim to `go install github.com/rhysd/actionlint/cmd/actionlint@<ACTIONLINT_VERSION>`, so it carries its leading `v`

### Requirement: Query Tools Bootstrap Action
The composite action `.github/actions/bootstrap-query-tools` SHALL, for jq and yq when `install_jq`/`install_yq` is truthy (`true`, `1` or `yes`, case-insensitive; default `false`), download the linux-amd64 release at the lock-file version or the `jq_version`/`yq_version` override, verify its SHA-256 against the lock file or the `jq_sha256`/`yq_sha256` override, and install it to `/usr/local/bin`.

#### Scenario: Checksum mismatch
- **WHEN** the downloaded binary's SHA-256 differs from the expected value, including when only a version override is supplied and the lock-file checksum is used
- **THEN** the action fails, printing expected and actual digests, without installing the binary

#### Scenario: Missing lock file or values
- **WHEN** the file at `tool_versions_lock_path` (default `.github/ci/tool-versions.lock`) does not exist, the resolved version or checksum of a requested tool is empty, or the download fails
- **THEN** the action fails

#### Scenario: Installed version outputs
- **WHEN** the action completes
- **THEN** `jq_version_installed` and `yq_version_installed` hold the version reported by each installed binary with the `jq-` or `v` prefix removed
- **AND** the output of a tool that was not requested is empty

### Requirement: Bootstrap Query Tools Smoke Test
The `bootstrap-query-tools-smoke` job of Validate Planner Contracts SHALL install jq and yq through the bootstrap-query-tools action and fail unless the action outputs `jq_version_installed` and `yq_version_installed` equal `JQ_VERSION` and `YQ_VERSION` sourced from the lock file. The job SHALL have no actor, fork or environment condition, so it also runs for Dependabot and fork pull requests.

#### Scenario: Installed versions match the lock
- **WHEN** both installed versions equal the lock-file values
- **THEN** the smoke job succeeds

#### Scenario: Installed version drifts from the lock
- **WHEN** either installed version differs from its lock-file value
- **THEN** the `Assert pinned versions` step fails

### Requirement: Stacks Gitlink Trust Check
The `stacks-sha-trust` job SHALL resolve the stacks gitlink with `git rev-parse HEAD:stacks` and pass it to `.github/scripts/stacks/verify_trusted_stacks_sha.sh` with `GITHUB_TOKEN` and `STACKS_REPO_READ_TOKEN` set and `WAIT_FOR_SUCCESS` unset, so trust is evaluated once without polling, and the job SHALL fail when the script exits non-zero.

#### Scenario: Gitlink not trusted
- **WHEN** the script reports the gitlink SHA as not trusted, including when the stacks commit's CI signals have not completed yet
- **THEN** the job fails without waiting for those signals

#### Scenario: Gitlink trusted
- **WHEN** the script exits zero for the gitlink SHA
- **THEN** the job succeeds

#### Scenario: Pull request merge result
- **WHEN** the job runs for a `pull_request` event
- **THEN** the evaluated SHA is the `stacks` gitlink in the checked-out pull request merge commit

### Requirement: GitHub Actions Lint Checks
Lint GitHub Actions SHALL install actionlint with `go install` (Go 1.24) at `ACTIONLINT_VERSION` and yamllint with pip at `YAMLLINT_VERSION`, then run `actionlint -color`, run yamllint on `.github/ci`, `.github/workflows` and `.github/dependabot.yml` with an inline config extending `default` that disables `truthy`, `line-length` and `document-start`, and parse every `.yml`/`.yaml` file under `.github` with `yq eval '.'`.

#### Scenario: actionlint finding
- **WHEN** actionlint reports any issue in the repository's workflows
- **THEN** the `lint` job fails

#### Scenario: yamllint error
- **WHEN** a linted file has an error-level violation of the yamllint `default` rules other than the three disabled ones
- **THEN** the `lint` job fails

#### Scenario: Unparseable YAML under .github
- **WHEN** any `.yml` or `.yaml` file anywhere under `.github`, including `.github/actions`, cannot be parsed by yq
- **THEN** the `Run yq parse checks` step fails

### Requirement: Weekly Galaxy Collection Update Check
Check Ansible Galaxy Updates SHALL run on cron `0 9 * * 1` (Mondays 09:00 UTC) and on `workflow_dispatch`, compare each collection's pinned `version` in `ansible/requirements.yml` with `highest_version.version` from the Galaxy v3 collections index API, and fail with an `::error::` annotation when at least one pinned version differs from the latest.

#### Scenario: Outdated collection
- **WHEN** a collection's pinned version is not equal to the Galaxy `highest_version.version`
- **THEN** a `::warning::<name>: pinned <pinned>, latest <latest>` annotation is emitted for it
- **AND** the job fails reporting the number of outdated collections

#### Scenario: Galaxy lookup fails
- **WHEN** the request to `https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/index/<namespace>/<name>/` fails after `curl --retry 3 --max-time 10` or returns no `highest_version.version`
- **THEN** a `::warning::Could not fetch latest version for <name>` annotation is emitted and that collection is not counted as outdated

#### Scenario: All collections current
- **WHEN** every pinned version equals its Galaxy latest version
- **THEN** the job succeeds

### Requirement: Dependabot Update Schedules
`.github/dependabot.yml` SHALL configure version updates for `gitsubmodule` at `/` daily, `github-actions` at `/` weekly on Monday, and `terraform` weekly on Monday for `/terraform`, `/terraform/infra`, `/terraform/oci`, `/terraform/gcp`, `/terraform/portainer` and `/terraform/portainer-root`, each with commit-message prefix `chore` and `include: scope`.

#### Scenario: Dependabot submodule bump pull request
- **WHEN** Dependabot opens a pull request bumping the `stacks` gitlink
- **THEN** the four pull_request validation workflows run through their `stacks` path filter
- **AND** `tfc-speculative-plan` and `stacks-sha-trust` are skipped for `dependabot[bot]`

#### Scenario: Galaxy collections outside Dependabot
- **WHEN** collections pinned in `ansible/requirements.yml` fall behind Galaxy
- **THEN** no Dependabot ecosystem updates them and the weekly Check Ansible Galaxy Updates workflow reports them instead
