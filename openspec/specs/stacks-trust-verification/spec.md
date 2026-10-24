# stacks-trust-verification Specification

## Purpose
Before anything uses the `stacks` submodule gitlink SHA (repository `JoseStud/stacks`), confirm that the commit is on the stacks `main` lineage and that its GitHub CI signals are green. The check is implemented by `.github/scripts/stacks/verify_trusted_stacks_sha.sh`. It runs as a preflight in the orchestrator, and as a check on pull requests and pushes in the validate-planner-contracts workflow.

## Requirements

### Requirement: Stacks SHA Argument Validation
`verify_trusted_stacks_sha.sh` SHALL take exactly one positional argument and SHALL reject it unless it matches `^[0-9a-f]{40}$` (`is_valid_sha` in `.github/scripts/lib/workflow_common.sh`), exiting with status 1 before any GitHub API request is made. The script SHALL also exit with status 1 when `jq` is not on `PATH`.

#### Scenario: Wrong argument count
- **WHEN** the script is invoked with zero arguments or with more than one argument
- **THEN** it prints `Usage: <script> <STACKS_SHA>` and exits with status 1

#### Scenario: Malformed SHA
- **WHEN** the argument is abbreviated, uppercase, or otherwise not 40 lowercase hexadecimal characters
- **THEN** the script prints `Invalid STACKS_SHA '<value>'. Expected a 40-character lowercase hexadecimal commit SHA.` and exits with status 1
- **AND** no compare, check-runs, or commit status request is sent

### Requirement: GitHub API Access and Token Selection
The script SHALL authenticate GitHub REST requests with `STACKS_REPO_READ_TOKEN` when it is non-empty and otherwise with `GITHUB_TOKEN`, exiting with status 1 when both are empty. Requests SHALL target `${GITHUB_API_URL}/repos/${STACKS_REPO_OWNER}/${STACKS_REPO_NAME}` (defaults `https://api.github.com`, `JoseStud`, `stacks`), and any non-200 response SHALL end the run with status 1.

#### Scenario: Dedicated stacks token preferred
- **WHEN** both `STACKS_REPO_READ_TOKEN` and `GITHUB_TOKEN` are set
- **THEN** every request carries `Authorization: Bearer <STACKS_REPO_READ_TOKEN>`, `Accept: application/vnd.github+json` and `X-GitHub-Api-Version: 2022-11-28`

#### Scenario: Fallback and missing token
- **WHEN** `STACKS_REPO_READ_TOKEN` is empty or unset and `GITHUB_TOKEN` is set
- **THEN** `GITHUB_TOKEN` is used as the bearer token
- **AND** when both are empty the script prints `Missing GitHub API token. Set STACKS_REPO_READ_TOKEN or GITHUB_TOKEN.` and exits with status 1

#### Scenario: API error response
- **WHEN** the compare request returns HTTP 403 or 404
- **THEN** the script prints a message saying that the token may lack access to `JoseStud/stacks` (403), or that the repository or SHA was not found (404)
- **AND** it exits with status 1

### Requirement: Main Branch Ancestry Check
The script SHALL request `GET .../compare/<STACKS_SHA>...<STACKS_MAIN_BRANCH>` (`STACKS_MAIN_BRANCH` defaults to `main`) once per run. It SHALL treat the SHA as on the trusted lineage only when the response `status` is `ahead` or `identical`. Any other value, including a missing status (reported as `unknown`), SHALL make the SHA untrusted and exit with status 1 before CI signals are queried.

#### Scenario: SHA is an ancestor of main
- **WHEN** the compare response status is `ahead` or `identical`
- **THEN** the script prints `Main ancestry result: pass (compare status: <status>)` and goes on to evaluate CI signals

#### Scenario: SHA is not on main
- **WHEN** the compare response status is `behind` or `diverged`
- **THEN** the script prints `Main ancestry result: fail (compare status: <status>)` and `Stacks SHA '<sha>' is NOT trusted.` and exits with status 1
- **AND** no check-runs or commit status request is sent

### Requirement: Check-Run Collection and De-duplication
The script SHALL list check runs with `GET .../commits/<STACKS_SHA>/check-runs?per_page=100&page=N`, starting at page 1. It SHALL stop when a page returns no runs or when the accumulated count reaches the `total_count` reported on page 1. It SHALL then de-duplicate the runs by `name` with jq `unique_by(.name)`, keeping the earliest-listed run for each name, and SHALL evaluate only the de-duplicated set.

#### Scenario: More than one page of check runs
- **WHEN** page 1 reports `total_count` 150
- **THEN** pages 1 and 2 are fetched and no further page is requested

#### Scenario: Repeated check name
- **WHEN** the API lists two runs named `validate`, first a `success` run and later a `failure` run
- **THEN** only the earlier-listed `success` run is classified

### Requirement: Check-Run Conclusion Classification
A de-duplicated check run SHALL pass only when its `status` is `completed` and its `conclusion` is `success`, `neutral`, or `skipped`. A run whose status is not `completed` SHALL count as incomplete. A completed run with any other conclusion SHALL count as a hard failure. The check-run channel SHALL be present when `total_count` > 0, and ready when it is present and has no incomplete or failing runs.

#### Scenario: Neutral and skipped runs pass
- **WHEN** every de-duplicated run is `completed` with conclusion `success`, `neutral`, or `skipped`
- **THEN** the check-run channel is ready

#### Scenario: Run still in progress
- **WHEN** a run has status `queued` or `in_progress`
- **THEN** it is listed under `Failing or incomplete check-runs:` with its status and conclusion
- **AND** the check-run channel is not ready, but no hard failure is recorded

#### Scenario: Completed with a failing conclusion
- **WHEN** a run is `completed` with conclusion `failure`, `cancelled`, `timed_out`, `action_required`, or null
- **THEN** a check-run hard failure is recorded

### Requirement: Legacy Combined Status Handling
The script SHALL request `GET .../commits/<STACKS_SHA>/status` and SHALL treat the legacy status channel as present only when the `statuses` array is non-empty. When the channel is present, a combined `state` of `success` SHALL make it ready, and `failure` or `error` SHALL record a hard failure. Any other state, such as `pending`, SHALL leave the channel not ready without recording a hard failure.

#### Scenario: No legacy status contexts
- **WHEN** the combined status response has an empty `statuses` array
- **THEN** the legacy channel is absent and its `state` value does not affect the trust decision

#### Scenario: Legacy status error
- **WHEN** `statuses` is non-empty and the combined `state` is `failure` or `error`
- **THEN** a legacy-status hard failure is recorded

### Requirement: Trust Decision Across Signal Channels
The script SHALL set `ready=true` only when at least one signal channel (check runs or legacy statuses) is present, neither channel records a hard failure, and every present channel is ready. When no channel is present, it SHALL print `No CI trust signals found yet. At least one green GitHub Checks or legacy commit status signal is required.` and treat the SHA as not ready.

#### Scenario: Check runs only
- **WHEN** all check runs pass and there are no legacy status contexts
- **THEN** the SHA is ready

#### Scenario: One present channel not green
- **WHEN** all check runs pass but legacy statuses exist with combined state `pending`
- **THEN** the SHA is not ready and no hard failure is recorded

#### Scenario: No CI signals yet
- **WHEN** check-runs `total_count` is 0 and the `statuses` array is empty
- **THEN** the script prints the no-signals message and the SHA is not ready

### Requirement: One-Shot Verification Mode
When `WAIT_FOR_SUCCESS` is not truthy (`to_bool`: `true`, `1`, or `yes`, case-insensitive; default `false`), the script SHALL evaluate the signals exactly once. It SHALL exit with status 0 and print `Stacks SHA '<sha>' is trusted.` only when the SHA is ready. Otherwise it SHALL exit with status 1 and print `Stacks SHA '<sha>' is NOT trusted.`, which includes the cases where checks are still pending and where no signals exist yet.

#### Scenario: Green signals
- **WHEN** ancestry passes and the SHA is ready
- **THEN** the script exits with status 0

#### Scenario: Pending checks fail immediately
- **WHEN** ancestry passes but a check run is still `in_progress`
- **THEN** the script exits with status 1 without polling

### Requirement: Wait-For-Success Polling Mode
When `WAIT_FOR_SUCCESS` is truthy, the script SHALL re-evaluate signals every `POLL_INTERVAL_SECONDS` (default 15) until `WAIT_TIMEOUT_SECONDS` (default 900) have elapsed. It SHALL exit with status 0 on the first ready result, exit with status 1 as soon as a hard failure is seen, and exit with status 1 on timeout. Both settings MUST be integers greater than 0, or the script SHALL exit with status 1 at startup.

#### Scenario: Checks turn green while polling
- **WHEN** early polls report pending checks and a later poll reports the SHA ready
- **THEN** the script prints `Stacks SHA '<sha>' is trusted.` and exits with status 0

#### Scenario: Terminal failure stops polling
- **WHEN** a poll records a check-run or legacy-status hard failure
- **THEN** the script prints `Stacks SHA '<sha>' is NOT trusted due to terminal check failure.` and exits with status 1 before the timeout

#### Scenario: Timeout
- **WHEN** the SHA never becomes ready within `WAIT_TIMEOUT_SECONDS`
- **THEN** the script prints `Timed out after <N>s waiting for stacks SHA '<sha>' checks to succeed.` and exits with status 1

### Requirement: Orchestrator Preflight Enforcement
The `dagger-pipeline` job of `.github/workflows/orchestrator.yml` SHALL run the script through `preflight.stacks_sha_trust` in a `base`-profile Dagger container with `WAIT_FOR_SUCCESS=true` and no Tailscale proxy. `WAIT_TIMEOUT_SECONDS` and `POLL_INTERVAL_SECONDS` SHALL come from the runner environment (defaults `900` and `15`), and `GITHUB_TOKEN` and `STACKS_REPO_READ_TOKEN` SHALL be attached as Dagger secrets when non-empty. A failed check SHALL abort the pipeline.

#### Scenario: Trust failure aborts the pipeline
- **WHEN** the script exits with a non-zero status inside the Dagger container
- **THEN** the pipeline process exits with status 1
- **AND** network-policy-sync, Cloudflare DNS sync, Ansible, and Portainer stages do not run

#### Scenario: Position in the run
- **WHEN** the `dagger-pipeline` job runs after `infra-apply` has succeeded or been skipped
- **THEN** stacks-sha-trust runs concurrently with secret-validation
- **AND** when inventory is needed, both run only after inventory-handover has completed

#### Scenario: No stacks SHA supplied
- **WHEN** `STACKS_SHA` is empty
- **THEN** the stage prints `stacks-sha-trust: skipped (no stacks_sha)` and does not run the script

### Requirement: Pull Request and Push Gate
The `stacks-sha-trust` job in `.github/workflows/validate-planner-contracts.yml` SHALL run on `push` and `pull_request` events that touch its watched paths, including `stacks` and `.gitmodules`. It SHALL resolve the gitlink with `git rev-parse HEAD:stacks` and run the script in one-shot mode (no `WAIT_FOR_SUCCESS`), passing the workflow `GITHUB_TOKEN` and the `STACKS_REPO_READ_TOKEN` secret. It SHALL be skipped for `dependabot[bot]` and for fork pull requests.

#### Scenario: Stacks CI still running
- **WHEN** a same-repository pull request points the gitlink at a stacks SHA whose CI is still in progress
- **THEN** the job fails without waiting for the stacks CI to finish

#### Scenario: Fork pull request
- **WHEN** the pull request head repository differs from `github.repository`
- **THEN** the `stacks-sha-trust` job is skipped

#### Scenario: Dependabot actor
- **WHEN** the triggering actor is `dependabot[bot]`
- **THEN** the `stacks-sha-trust` job is skipped
