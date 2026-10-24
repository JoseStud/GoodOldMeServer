# node-provisioning Specification

## Purpose
Defines how the OCI worker nodes and the GCP witness are reached by Ansible and given a base system: the inventory sources, the CI Ansible runner (credentials, ephemeral SSH certificate, Tailscale-aware inventory patching, secret injection), the three-play provisioning playbook with its phase tags, and the phase 1-3 roles (service user, block storage, Infisical CLI, Docker, Tailscale).

## Requirements

### Requirement: CI Inventory Rendering
`.github/scripts/tfc/render_inventory_from_tfc_outputs.sh <workspace> [output_file]` SHALL require `TFC_TOKEN` and `TFC_ORGANIZATION`, read the current state outputs of the Terraform Cloud workspace, and write a static YAML inventory (default `inventory-ci.yml`) with hosts `oci-node-N` (public IPv4, user `ubuntu`) and `gcp-witness` (Tailscale hostname, user `debian`) grouped into `oci_nodes` and `gcp_witness`.

#### Scenario: Inventory rendered from workspace outputs
- **WHEN** the workspace (`TFC_WORKSPACE_INFRA`, default `goodoldme-infra`) exposes `oci_public_ips` = `["IP1","IP2"]` and `gcp_witness_tailscale_hostname` = `swarm-witness`
- **THEN** the inventory lists `oci-node-1` with `ansible_host: "IP1"` and `oci-node-2` with `ansible_host: "IP2"`, numbered from 1 in output order, each with `ansible_user: "ubuntu"`
- **AND** it lists `gcp-witness` with `ansible_host: "swarm-witness"` and `ansible_user: "debian"`, with group `oci_nodes` holding the `oci-node-N` hosts and group `gcp_witness` holding `gcp-witness`

#### Scenario: Required output missing
- **WHEN** `oci_public_ips` is missing, null or an empty list, or `gcp_witness_tailscale_hostname` is missing
- **THEN** the script exits with status 1 and a message naming the missing output, without writing the inventory file

### Requirement: Local Operator Configuration
`ansible/ansible.cfg` SHALL set the default inventory to `inventory/terraform.yml`, `host_key_checking = True`, `remote_user = ubuntu`, `interpreter_python = auto_silent`, and SSH args presenting `~/.ssh/id_ed25519-cert.pub` with identity `~/.ssh/id_ed25519`; `ansible/inventory/terraform.yml` SHALL select the `cloud.terraform.terraform_provider` inventory plugin with `project_path: ../../terraform/infra`.

#### Scenario: Running from the ansible directory
- **WHEN** an operator runs `ansible-playbook` with `ansible/` as the working directory and no `-i` argument
- **THEN** Ansible loads `ansible/ansible.cfg` and uses `inventory/terraform.yml`, which points the `cloud.terraform.terraform_provider` plugin at `../../terraform/infra`
- **AND** SSH connections present the certificate `~/.ssh/id_ed25519-cert.pub` and key `~/.ssh/id_ed25519` as user `ubuntu` unless the inventory overrides it

### Requirement: CI Ansible Invocation
The pipeline SHALL run Ansible as a host subprocess through `ansible_run()` in `ci/src/ci_pipeline/phases/ansible.py`, which sets `INVENTORY_FILE` (default `inventory-ci.yml`) and, when non-empty, `STACKS_SHA` and `ANSIBLE_TAGS`, executes `bash .github/scripts/stages/ansible_run.sh`, and exits with the script's return code on failure.

#### Scenario: Bootstrap or host sync
- **WHEN** `RUN_ANSIBLE_BOOTSTRAP` or `RUN_HOST_SYNC` is `true`
- **THEN** the inventory rendered from the infra workspace is exported to `inventory-ci.yml` and `ansible_run` is called with `STACKS_SHA` and the `ANSIBLE_TAGS` value of the execution context
- **AND** when `RUN_HOST_SYNC` is `true` and `RUN_ANSIBLE_BOOTSTRAP` is not, the tags passed are `phase7_runtime_sync`

#### Scenario: Config sync
- **WHEN** `RUN_CONFIG_SYNC` is `true` and an inventory was rendered
- **THEN** the inventory is exported again and a separate `ansible_run` with tags `sync-configs` runs after the bootstrap/host-sync run and after the post-bootstrap secret check (when Portainer apply is enabled), before the Portainer API preflight

#### Scenario: Runner failure
- **WHEN** `ansible_run.sh` exits with a non-zero status
- **THEN** `ansible-run: FAILED` is printed to stderr and the pipeline process exits with the same status

### Requirement: Runner Preparation
`.github/scripts/stages/ansible_run.sh` SHALL require `INFISICAL_PROJECT_ID` and `INVENTORY_FILE`, then in order check out `STACKS_SHA` into `stacks/` when set, obtain an Infisical token, generate the SSH certificate, install the Galaxy collections pinned in `ansible/requirements.yml` unless they are unchanged, and stop before inventory patching when `SHADOW_MODE` is true.

#### Scenario: Stacks commit pinned for the run
- **WHEN** `STACKS_SHA` is set and `stacks/` is a git work tree
- **THEN** the runner runs `git fetch --depth=1 origin <sha>` and `git checkout --detach --force <sha>` in `stacks/`
- **AND** when `stacks/` has no git metadata it initializes a repository there with origin `STACKS_REPO_URL` (default `https://github.com/JoseStud/stacks`), fetches the SHA at depth 1 and checks out `FETCH_HEAD` detached

#### Scenario: Collections unchanged since last install
- **WHEN** the sha256 of `ansible/requirements.yml` equals the content of `~/.ansible/collections/.requirements_hash`
- **THEN** `ansible-galaxy collection install` is skipped
- **AND** otherwise `community.general` 12.4.0, `ansible.posix` 2.1.0, `community.docker` 5.0.6 and `cloud.terraform` 4.0.0 are installed and the new hash is written to the marker file

#### Scenario: Shadow mode
- **WHEN** `SHADOW_MODE` is `true`, `1` or `yes` (case-insensitive)
- **THEN** the runner prints `SHADOW_MODE=true: skipping Ansible mutation run.` and exits 0 after certificate generation and collection install
- **AND** the inventory is not patched and `ansible-playbook` is not run

### Requirement: Playbook Execution Environment
The runner SHALL export `INFISICAL_TOKEN` (reusing a non-empty one, else Universal Auth when `INFISICAL_AGENT_CLIENT_ID` and `INFISICAL_AGENT_CLIENT_SECRET` are set, else a GitHub OIDC exchange for `INFISICAL_MACHINE_IDENTITY_ID`) and run `ansible-playbook -i $INVENTORY_FILE ansible/playbooks/provision.yml` inside nested `infisical run --env=prod` calls for `/infrastructure` and then `/stacks/management`.

#### Scenario: Token source precedence
- **WHEN** `INFISICAL_TOKEN` is empty and both `INFISICAL_AGENT_CLIENT_ID` and `INFISICAL_AGENT_CLIENT_SECRET` are set
- **THEN** the runner obtains an access token from `<INFISICAL_DOMAIN>/api/v1/auth/universal-auth/login` (default domain `https://app.infisical.com`) and exports it as `INFISICAL_TOKEN`
- **AND** when neither a token nor agent credentials are present it exchanges a GitHub Actions OIDC JWT (audience `INFISICAL_OIDC_AUDIENCE` when set) at `/api/v1/auth/oidc-auth/login` instead

#### Scenario: Secrets and connection settings for the playbook
- **WHEN** the playbook is launched
- **THEN** secrets from Infisical `/infrastructure` (such as `TAILSCALE_AUTH_KEY`) and `/stacks/management` are present in the `ansible-playbook` environment
- **AND** `ANSIBLE_SSH_ARGS` is `-o StrictHostKeyChecking=accept-new -o CertificateFile=~/.ssh/id_ed25519-cert.pub -i ~/.ssh/id_ed25519`, `ANSIBLE_ROLES_PATH` is `ansible/roles` and `ANSIBLE_TIMEOUT` defaults to 30

#### Scenario: Tag filter passthrough
- **WHEN** `ANSIBLE_TAGS` is non-empty
- **THEN** `--tags <ANSIBLE_TAGS>` is appended to the `ansible-playbook` arguments
- **AND** when it is empty no tag filter is passed

### Requirement: Ephemeral SSH Certificate
`generate_ephemeral_ssh_certificate` SHALL require `SSH_CERT_PRINCIPALS`, reuse `~/.ssh/id_ed25519` when both key files exist or else create a passphrase-less ed25519 keypair, delete any existing `~/.ssh/id_ed25519-cert.pub`, and sign the public key with `SSH_CA_PRIVATE_KEY` from Infisical `/security` using identity `ci-<epoch>`, the given principals and validity `+1h`.

#### Scenario: Certificate issued
- **WHEN** `SSH_CERT_PRINCIPALS` is `ubuntu,debian` and the CA key is available
- **THEN** `~/.ssh/id_ed25519-cert.pub` is produced for principals `ubuntu,debian`, valid for one hour
- **AND** the CA key, written to a mode 0600 temporary file, is shredded or removed when the function returns

#### Scenario: CA key unavailable
- **WHEN** fetching `SSH_CA_PRIVATE_KEY` from `/security` yields an empty value
- **THEN** the function prints `Failed to fetch SSH_CA_PRIVATE_KEY from Infisical /security` and returns 1, which aborts the runner before Ansible runs

### Requirement: SSH Transport Selection
`ansible_run.sh` SHALL force `PREFER_TAILSCALE_SSH=true` whenever `RUN_INFRA_APPLY` is not `true`, resolving every `oci-node-N` host to its Tailscale IPv4 in addition to non-IP hosts; when `RUN_INFRA_APPLY` is `true` and `PREFER_TAILSCALE_SSH` keeps its default `false`, OCI hosts SHALL keep their public IPv4 `ansible_host` and only non-IP hosts (the witness) are resolved via Tailscale.

#### Scenario: Run without infra apply
- **WHEN** `RUN_INFRA_APPLY` is unset or any value other than `true`
- **THEN** `PREFER_TAILSCALE_SSH` is set to `true` regardless of its incoming value
- **AND** each `oci-node-N` alias listed under `all.hosts`, as well as the witness hostname, has its `ansible_host` replaced with the resolved Tailscale IPv4 address

#### Scenario: Run after infra apply
- **WHEN** `RUN_INFRA_APPLY` is `true` and `PREFER_TAILSCALE_SSH` is not `true`
- **THEN** the `oci-node-N` hosts keep the public IPv4 `ansible_host` values from the rendered inventory
- **AND** only `ansible_host` values that are not IPv4 literals, i.e. the witness Tailscale hostname, are resolved and replaced

#### Scenario: Explicit Tailscale preference with infra apply
- **WHEN** `RUN_INFRA_APPLY` is `true` and `PREFER_TAILSCALE_SSH` is `true`
- **THEN** the `oci-node-N` aliases are resolved to Tailscale IPv4 addresses as in a run without infra apply

### Requirement: Tailscale Peer Resolution
For each host to resolve, the runner SHALL poll `tailscale ip -4 <name>` (also trying `app-worker-N` for `oci-node-N`) every `TAILSCALE_PEER_POLL_INTERVAL` seconds (default 15) for up to `TAILSCALE_PEER_WAIT_SECONDS` (default 300), write the first IPv4 found into the inventory file in place, and fail before `ansible-playbook` runs when a peer is never found.

#### Scenario: Legacy hostname fallback
- **WHEN** `oci-node-2` is not known to Tailscale but `app-worker-2` is
- **THEN** the IPv4 of `app-worker-2` is written as the `ansible_host` of the `oci-node-2` entry (the first `ansible_host` line after that host key)

#### Scenario: Peer never appears
- **WHEN** no candidate name resolves within `TAILSCALE_PEER_WAIT_SECONDS`
- **THEN** the runner prints `ERROR: Tailscale peer '<name>' not found after <N>s.`, emits `tailscale status`, `tailscale ping -c 1 <name>` and `tailscale ip <name>` diagnostics with remediation hints, and exits non-zero without running `ansible-playbook`

#### Scenario: Tailscale CLI absent
- **WHEN** the `tailscale` command is not installed on the runner
- **THEN** hostname resolution is skipped with a log message and the inventory is used unchanged

### Requirement: Playbook Structure And Phase Tags
`ansible/playbooks/provision.yml` SHALL contain three plays with `become: true` and `gather_facts: false`: `Bootstrap OCI infrastructure` (`oci_nodes`, `strategy: free`, phases 1-3), `Bootstrap GCP witness over Tailscale` (`gcp_witness`, `strategy: free`, phases 1-3 without storage) and `Provision clustered services` (`all`, default strategy, phases 4-7), with phase tags on each include statement.

#### Scenario: Connection gating tasks
- **WHEN** any play starts, with or without a tag filter
- **THEN** its `always`-tagged tasks run: in the first two plays `wait_for_connection` (delay 10, timeout 600 for OCI nodes and 900 for the witness), `setup` and `ping`; in the third play `ping`

#### Scenario: Full run order
- **WHEN** the playbook runs without a tag filter
- **THEN** OCI nodes run system_user, storage, infisical_cli, docker and tailscale, the witness runs system_user, infisical_cli, docker and tailscale, and only after both plays finish all hosts run glusterfs, sync-configs, swarm, portainer_bootstrap and runtime_sync
- **AND** portainer_bootstrap is included only when `inventory_hostname == groups['oci_nodes'][0]`

#### Scenario: Phase tag assignment
- **WHEN** a tag filter is supplied
- **THEN** it is matched against include statements tagged `phase1_base` (system_user, storage, infisical_cli), `phase2_docker` (docker), `phase3_tailscale` (tailscale), `phase4_glusterfs` (glusterfs, included with `public: true`), `phase4_glusterfs` and `sync-configs` (`../roles/glusterfs/tasks/sync-configs.yml`), `phase5_swarm` (swarm), `phase6_portainer` (portainer_bootstrap) and `phase7_runtime_sync` (runtime_sync)
- **AND** the always-tagged connection tasks and the matching include tasks execute, while tasks inside the included roles and task files carry no inherited tags

### Requirement: Base System Setup
Phase 1 SHALL create group `media-srv` (gid 1500) and user `media-srv` (uid 1500, primary group `media-srv`, no home directory) on every node, and SHALL install the `infisical` package from the APT repository `https://artifacts-cli.infisical.com/deb stable main` signed by `/usr/share/keyrings/infisical-cli-archive-keyring.gpg` (key from `https://artifacts-cli.infisical.com/infisical.gpg`).

#### Scenario: Service account and CLI present
- **WHEN** phase 1 runs on an OCI node or the witness
- **THEN** user and group `media-srv` exist with uid and gid 1500
- **AND** the `infisical` CLI package is installed from the `infisical-cli` APT source

#### Scenario: APT lock contention
- **WHEN** another apt process holds the dpkg lock during installation of the prerequisites (`ca-certificates`, `gnupg`) or of `infisical`
- **THEN** each of those apt tasks waits up to 300 seconds for the lock and is retried up to 5 times with a 20 second delay

### Requirement: OCI Block Volume Storage
On `oci_nodes` only, phase 1 SHALL ensure partition 1 exists on `block_device` `/dev/sdb`, an ext4 filesystem exists on `/dev/sdb1` (suffix `p1` for nvme/mmcblk devices), the partition is mounted at `/mnt/app_data` with a persistent mount entry, and `/mnt/app_data` is owned by `media-srv:media-srv` with mode 0755.

#### Scenario: Fresh block volume
- **WHEN** an OCI node has an unpartitioned `/dev/sdb`
- **THEN** `/dev/sdb1` is created, formatted as ext4 and mounted at `/mnt/app_data`

#### Scenario: Re-run on a provisioned volume
- **WHEN** `/dev/sdb1` already exists with an ext4 filesystem and is mounted
- **THEN** the partition and filesystem are left in place without reformatting and only ownership and mode are enforced

#### Scenario: Witness excluded
- **WHEN** the witness play runs phase 1
- **THEN** the storage role is not included

### Requirement: Docker Engine Installation
Phase 2 SHALL install `docker-ce`, `docker-ce-cli`, `containerd.io` and `docker-compose-plugin` from `https://download.docker.com/linux/<distribution>` (key `/etc/apt/keyrings/docker.asc`, arch mapped to amd64/arm64) only when `/usr/bin/docker` is absent, and on every run SHALL keep the `docker` service started and enabled and append `media-srv` to the `docker` group.

#### Scenario: Docker already present
- **WHEN** `/usr/bin/docker` exists
- **THEN** the APT repository and package installation steps are skipped
- **AND** the service state and `docker` group membership are still enforced

#### Scenario: OCI DNS stub listener disabled
- **WHEN** the host is in `oci_nodes`, uses systemd and runs Ubuntu
- **THEN** `DNSStubListener=no` is set under `[Resolve]` in `/etc/systemd/resolved.conf` (with a backup) if that file exists, and `/etc/resolv.conf` is force-linked to `/run/systemd/resolve/resolv.conf` if that file exists
- **AND** `systemd-resolved` is restarted only when either of those changes was made

#### Scenario: Witness DNS untouched
- **WHEN** the host is the GCP witness
- **THEN** the systemd-resolved tasks are skipped

### Requirement: Tailscale Enrollment
Phase 3 SHALL install `tailscale` from `https://pkgs.tailscale.com/stable/<distribution>` when `/usr/bin/tailscale` is absent, keep `tailscaled` started and enabled, run `tailscale up --authkey=<TAILSCALE_AUTH_KEY> --ssh --accept-dns=false --reset` only when `tailscale status --json` fails or its `BackendState` is not `Running`, and then verify that the backend is `Running`.

#### Scenario: Node already connected
- **WHEN** `tailscale status --json` succeeds with `BackendState` `Running`
- **THEN** no authentication is attempted and `TAILSCALE_AUTH_KEY` is not required
- **AND** the verification step passes

#### Scenario: Node needs authentication
- **WHEN** the backend is not `Running`
- **THEN** the role asserts that the controller environment variable `TAILSCALE_AUTH_KEY` is non-empty, failing with a message pointing to Infisical `/infrastructure` otherwise
- **AND** it launches `tailscale up` asynchronously (async 120, poll 0, `no_log`), waits for the connection to return (delay 5, timeout 120) and polls the job until finished (24 retries, 5 second delay)

#### Scenario: Verification failure
- **WHEN** the follow-up `tailscale status --json` fails or its `BackendState` is not `Running`
- **THEN** the role prints the `tailscaled` journal from the last 3 minutes and fails with `Tailscale verification failed on <host>`
