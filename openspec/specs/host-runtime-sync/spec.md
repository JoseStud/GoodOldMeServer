# host-runtime-sync Specification

## Purpose
Phase 7 of `ansible/playbooks/provision.yml` (role `ansible/roles/runtime_sync`), run on every inventory host: mirror the trusted `stacks/` checkout to `/opt/stacks` and install the host-side Infisical Agent with its config, credentials, helper scripts and systemd unit. The agent renders runtime secrets into stack files and triggers redeploys from the primary manager.

## Requirements

### Requirement: Controller Secret Assertion
Before changing any host, the role SHALL assert once on the controller (delegated to localhost, without logging) that `INFISICAL_PROJECT_ID`, `INFISICAL_AGENT_CLIENT_ID` and `INFISICAL_AGENT_CLIENT_SECRET` are all non-empty in the controller environment.

#### Scenario: All controller secrets present
- **WHEN** the three variables are non-empty in the playbook's environment
- **THEN** the assertion passes and the role continues on every host

#### Scenario: A controller secret is missing
- **WHEN** any of the three variables is empty or unset
- **THEN** the assertion fails before packages, directories or files are touched on any host

### Requirement: Runtime Packages And Directories
On every host the role SHALL install `curl` and `rsync` with apt (refreshing the cache) when either is missing from the apt package facts. It SHALL ensure these root:root directories: `/opt/stacks` (0750), `/etc/infisical` (0750), `/var/lib/infisical/cache` (0700), and `/mnt/app_data/local/auth/authelia-db` and `/mnt/app_data/local/management/homarr-db` (both 0777).

#### Scenario: Packages already installed
- **WHEN** both `curl` and `rsync` appear in the gathered apt package facts
- **THEN** the apt install task is skipped

#### Scenario: Directories converged
- **WHEN** the role runs on any host, including the GCP witness
- **THEN** each of the five directories exists with owner root, group root and the listed mode

### Requirement: Trusted Stacks Mirror
The role SHALL push the controller's `stacks/` checkout (`{{ playbook_dir }}/../../stacks/`) to `/opt/stacks/` on every host using `ansible.posix.synchronize` (rsync archive, recursive, `--delete`, remote `sudo rsync`, Ansible's configured SSH arguments), excluding `.env`, `.git` and `.github`.

#### Scenario: File removed from the checkout
- **WHEN** a file exists under `/opt/stacks` but not in the controller checkout and is not named `.env`, `.git` or `.github`
- **THEN** rsync deletes it from `/opt/stacks`

#### Scenario: Rendered env files preserved
- **WHEN** a host has an agent-rendered `/opt/stacks/<stack>/.env`
- **THEN** the sync neither overwrites nor deletes it, and no `.git` or `.github` content is copied to the host

### Requirement: Template Placeholder Substitution
When the mirror task reports changed, the role SHALL find every `*.tmpl` file under `/opt/stacks`, recursively and including hidden files such as `.env.tmpl`. In each file it SHALL replace `__INFISICAL_PROJECT_ID__` with the controller's `INFISICAL_PROJECT_ID` value (without logging) and `__INFISICAL_ENV__` with `prod`, and it SHALL notify the `Restart infisical agent` handler when a replacement changes a file.

#### Scenario: Sync changed files
- **WHEN** the synchronize task reports changed
- **THEN** every `*.tmpl` under `/opt/stacks` has both placeholders replaced in place on the host
- **AND** the agent restart handler is notified when any file was modified

#### Scenario: Sync reported no change
- **WHEN** the synchronize task reports no change
- **THEN** the find and replace tasks are skipped

### Requirement: Root-Only Agent Credential Files
The role SHALL write `/etc/infisical/runtime-sync.env`, `/etc/infisical/client-id` and `/etc/infisical/client-secret` as root:root with mode 0600, without logging their contents. The env file SHALL define `INFISICAL_DOMAIN` (`https://app.infisical.com`), `INFISICAL_ENV` (`prod`), `INFISICAL_PROJECT_ID`, `INFISICAL_AGENT_CLIENT_ID` and `INFISICAL_AGENT_CLIENT_SECRET`. The client-id and client-secret files SHALL hold the bare value followed by a newline.

#### Scenario: Credential rotation
- **WHEN** `INFISICAL_AGENT_CLIENT_ID` or `INFISICAL_AGENT_CLIENT_SECRET` differs from the content on the host
- **THEN** the corresponding file is rewritten and the `Restart infisical agent` handler is notified

#### Scenario: Env file change only
- **WHEN** only `/etc/infisical/runtime-sync.env` changes
- **THEN** the file is rewritten without notifying the agent restart handler, and the helper scripts read the new values the next time they run

### Requirement: Portainer Webhook Helper
The role SHALL install `/usr/local/bin/portainer-stack-webhook` (root, 0700). Given exactly one stack name, the helper SHALL source `/etc/infisical/runtime-sync.env`, get a token via `infisical login --method=universal-auth`, read `WEBHOOK_URL_<STACK>` (upper-cased, `-` turned into `_`) from Infisical `/deployments`, and POST to that URL. It SHALL succeed only on HTTP 200 or 204.

#### Scenario: Webhook triggered
- **WHEN** `portainer-stack-webhook auth` runs and `WEBHOOK_URL_AUTH` exists in Infisical `/deployments`
- **THEN** the helper POSTs to that URL and, on HTTP 200 or 204, prints `Triggered Portainer webhook for auth (HTTP <status>).` and exits 0

#### Scenario: Webhook URL missing
- **WHEN** the derived `WEBHOOK_URL_<STACK>` variable is empty or absent in `/deployments`
- **THEN** the helper prints `Missing WEBHOOK_URL_<STACK> in Infisical /deployments.` and exits 1

#### Scenario: Preconditions or call fail
- **WHEN** the argument count is not 1, `curl` or `infisical` is not on PATH, a required env file variable is empty, no token is obtained, or the POST returns a status other than 200 or 204
- **THEN** the helper exits with a non-zero status

### Requirement: Rendered Config Sync Helpers
The role SHALL install `/usr/local/bin/auth-users-database-sync` and `/usr/local/bin/observability-alertmanager-sync` (root, 0700). Each SHALL take one rendered file path and, when its GlusterFS target is missing or differs, install the file there with mode 0644 and run `portainer-stack-webhook` with `auth` or `observability`. The targets are `/mnt/swarm-shared/auth/authelia/config/users_database.yml` and `/mnt/swarm-shared/observability/alertmanager/alertmanager.yml`.

#### Scenario: Rendered content changed
- **WHEN** the rendered file differs from the shared target or the target does not exist
- **THEN** the helper creates the target directory if needed, installs the file with mode 0644, and triggers the stack webhook through `portainer-stack-webhook`

#### Scenario: Rendered content unchanged
- **WHEN** the shared target exists and `cmp -s` finds it identical to the rendered file
- **THEN** the helper prints that the file is already up to date and exits 0 without calling the webhook

#### Scenario: Rendered file absent
- **WHEN** the given rendered path does not exist, or the argument count is not 1
- **THEN** the helper exits 1 without touching the shared target

### Requirement: Infisical Agent Configuration
The role SHALL render the controller's `stacks/infisical-agent.yaml` as a Jinja template to `/etc/infisical/agent.yaml` (root, 0600). The result SHALL target `https://app.infisical.com` and use `universal-auth` with `/etc/infisical/client-id` and `/etc/infisical/client-secret` (`remove_client_secret_on_read: false`). Every template entry SHALL poll every 60s.

#### Scenario: Rendered template set
- **WHEN** the agent config is rendered on any host
- **THEN** it renders `/opt/stacks/<stack>/.env.tmpl` to the sibling `.env` for gateway, auth, management, network, observability, media/ai-interface, home-dashboard, uptime and cloud
- **AND** it renders `gateway/config/dynamic/homeassistant.yml.tmpl` to `/mnt/swarm-shared/gateway/traefik_dynamic/homeassistant.yml`, `auth/config/users_database.yml.tmpl` to `users_database.rendered.yml`, and `observability/config/alertmanager.yml.tmpl` to `alertmanager.rendered.yml` alongside their sources

#### Scenario: Agent config changed
- **WHEN** the rendered `/etc/infisical/agent.yaml` differs from the file on the host
- **THEN** the file is replaced and the `Restart infisical agent` handler is notified

### Requirement: Primary Manager Execute Commands
The rendered agent config SHALL attach execute commands (timeout 60) only to the auth users database, management `.env` and Alertmanager templates. On `groups['oci_nodes'][0]` they SHALL run, respectively: the auth sync helper; `set -a; . /opt/stacks/management/.env; set +a; docker stack deploy -c /opt/stacks/management/docker-compose.yml management`; and the Alertmanager sync helper. On every other host each command SHALL only print a skip message and exit 0.

#### Scenario: Management env re-rendered on the primary manager
- **WHEN** the agent on the primary manager renders `/opt/stacks/management/.env`
- **THEN** it exports the file's variables and runs `docker stack deploy -c /opt/stacks/management/docker-compose.yml management`, without `--with-registry-auth`

#### Scenario: Non-primary host
- **WHEN** one of these three templates is rendered on a host other than the primary manager
- **THEN** the command prints a message such as `Skipping management deploy on <host>; primary manager is <primary>.` and exits 0

#### Scenario: Env-only stacks
- **WHEN** the `.env` of gateway, auth, network, observability, ai-interface, home-dashboard, uptime or cloud is re-rendered
- **THEN** no command runs and no redeploy is triggered by the agent

### Requirement: Agent Service Management
The role SHALL install `/etc/systemd/system/infisical-agent.service` (root, 0644). The unit SHALL run `/usr/bin/infisical agent --config /etc/infisical/agent.yaml` as root with `Restart=always` and `RestartSec=10`, ordered after `network-online.target` and `docker.service`. The role SHALL keep the service enabled and started with a daemon reload. The `Restart infisical agent` handler SHALL restart it, with a daemon reload, when notified.

#### Scenario: Unit installed or changed
- **WHEN** the unit file is created or its content changes
- **THEN** the `Restart infisical agent` handler is notified and, when the play's handlers run, restarts `infisical-agent` after a systemd daemon reload

#### Scenario: Notifying task changed
- **WHEN** a credential file, helper script, the agent config or a substituted `*.tmpl` file changes during the run
- **THEN** `infisical-agent` is restarted by the handler, and the service is enabled and started in every case
