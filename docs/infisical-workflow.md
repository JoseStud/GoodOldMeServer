# Infisical Workflow

This document describes how secrets are managed and injected into the infrastructure using [Infisical](https://infisical.com).

## Overview

Infisical acts as the single source of truth for all secrets across Terraform, Ansible, and Docker Swarm stacks. Secrets are organized by path and injected at deploy time through either the Infisical SDK (Terraform) or the Infisical Agent (Docker Swarm).

```mermaid
flowchart LR
    INF[Infisical Cloud] -->|SDK read| TFI[Terraform infra workspace]
    INF -->|SDK read| TFP[Terraform portainer workspace]
    TFI -->|/cloud-provider/oci| OCI[OCI Provider]
    TFI -->|/cloud-provider/gcp| GCP[GCP Provider]
    TFP -->|/management| PORT[Portainer Provider]
    PORT -->|creates stacks + webhooks| SWARM[Docker Swarm]
    TFP -->|SDK write /deployments| INF
    INF -->|Agent| ENV[.env files<br/>rendered on host]
    ENV -->|/infrastructure + /stacks/*| STACKS[Docker Stack Deploy]
    INF -->|/deployments| AUTO[Private Automation<br/>Stacks repo cloud static runner]
```

## Secret Organization

| Path | Consumer | Secrets |
|------|----------|---------|
| `/infrastructure` | Terraform, Ansible, Scripts | `BASE_DOMAIN`, `CLOUDFLARE_API_TOKEN`, `TAILSCALE_AUTH_KEY`, `TZ`, `ZONE_ID` |
| `/management` | Terraform (Portainer provider), Operators | `PORTAINER_URL`, `PORTAINER_API_URL`, `PORTAINER_API_KEY`, `PORTAINER_LICENSE_KEY` |
| `/deployments` | Terraform (auto-written), Stacks repo cloud static runner | `PORTAINER_WEBHOOK_URLS`, `WEBHOOK_URL_*` |
| `/security` | Terraform (cloud-init), GitHub Actions (SSH) | `SSH_CA_PUBLIC_KEY`, `SSH_HOST_CA_PUBKEY` |
| `/stacks/gateway` | Traefik | `ACME_EMAIL`, `DOCKER_SOCKET_PROXY_URL` |
| `/stacks/identity` | Authelia SSO | `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `POSTGRES_PASSWORD`, `AUTHELIA_NOTIFIER_SMTP_USERNAME`, `AUTHELIA_NOTIFIER_SMTP_PASSWORD`, `AUTHELIA_NOTIFIER_SMTP_SENDER`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY` |
| `/stacks/management` | Homarr + Portainer | `HOMARR_SECRET_KEY`, `PORTAINER_ADMIN_PASSWORD`, `PORTAINER_ADMIN_PASSWORD_HASH`, `PORTAINER_AUTOMATION_ALLOWED_CIDRS` |
| `/stacks/network` | Vaultwarden, Pi-hole | `VW_DB_PASS`, `VW_ADMIN_TOKEN`, `PIHOLE_PASSWORD` |
| `/stacks/observability` | Grafana | `GF_OIDC_CLIENT_ID`, `GF_OIDC_CLIENT_SECRET`, `ALERTMANAGER_WEBHOOK_URL` |
| `/stacks/ai-interface` | Open WebUI | `ARCH_PC_IP` |
| `/cloud-provider/gcp` | Terraform (GCP provider) | `GCP_PROJECT_ID` |
| `/cloud-provider/oci` | Terraform (OCI provider) | `OCI_COMPARTMENT_OCID`, `OCI_IMAGE_OCID` |

> **Global injection:** `BASE_DOMAIN` is used in almost every `.env.tmpl` via a `{{- with secret "/infrastructure" }}` block, as Traefik requires it for routing labels. Other variables like `TZ` or `CLOUDFLARE_API_TOKEN` are only pulled into the specific stacks that need them.

---

## Complete Variable Reference

### Variable Ownership & Mutability

Use this as the source of truth for whether a value is operator-managed or automation-managed.

| Variable / Path | Owner | Mutability |
|-----------------|-------|------------|
| `/stacks/management/PORTAINER_ADMIN_PASSWORD_HASH` | Platform | Auto-generated/re-written by Ansible `portainer_bootstrap` on bootstrap runs. Do not set manually. |
| `/management/PORTAINER_URL`, `/management/PORTAINER_API_URL`, `/management/PORTAINER_API_KEY` | Platform | Auto-written by Ansible `portainer_bootstrap` after bootstrap (API key may be rotated). Do not set manually. |
| `/deployments/PORTAINER_WEBHOOK_URLS` + `/deployments/WEBHOOK_URL_*` | Platform | Auto-written by Terraform `portainer` module on Portainer workspace apply. Do not edit manually. |
| `TF_VAR_network_access_policy` (Terraform Cloud env var) | Security | Auto-created/updated by `infra-orchestrator.yml` `network-policy-sync` job. Do not set manually outside policy sync flow. |
| `/stacks/management/PORTAINER_AUTOMATION_ALLOWED_CIDRS` | Security | Auto-synced by `infra-orchestrator.yml` from `network_access_policy.portainer_api.source_ranges`. Do not set manually outside break-glass recovery. |

> For first-run setup and required GitHub/TFC inputs, see [Meta-Pipeline Cutover Checklist](meta-pipeline-cutover-checklist.md).

### Required for First Deploy

| Path | Variables | Requirement | Owner | Notes |
|------|-----------|-------------|-------|-------|
| `/infrastructure` | `BASE_DOMAIN`, `TZ`, `CLOUDFLARE_API_TOKEN`, `ZONE_ID`, `TAILSCALE_AUTH_KEY` | Required | Operator | Baseline globals for stack rendering, DNS, and provisioning |
| `/cloud-provider/oci` | `OCI_COMPARTMENT_OCID`, `OCI_IMAGE_OCID` | Required | Platform | Required for infra workspace apply |
| `/cloud-provider/gcp` | `GCP_PROJECT_ID` | Required | Platform | Required for infra workspace apply |
| `/security` | `SSH_CA_PUBLIC_KEY` (and host CA key if used) | Required | Security | Required for SSH certificate trust bootstrap |
| `/stacks/management` | `HOMARR_SECRET_KEY`, `PORTAINER_ADMIN_PASSWORD` | Required | Operator | Needed before Phase 6 Portainer bootstrap |
| `/stacks/gateway` | `ACME_EMAIL`, `DOCKER_SOCKET_PROXY_URL` | Required | Operator | Required for gateway stack certificate/Docker provider wiring |
| `/stacks/identity` | `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `POSTGRES_PASSWORD`, SMTP+OIDC secrets | Required | Security | Required for first auth deploy and SSO readiness |
| `/stacks/network` | `VW_DB_PASS`, `VW_ADMIN_TOKEN`, `PIHOLE_PASSWORD` | Required | Operator | Required for network stack stateful services |
| `/stacks/observability` | `GF_OIDC_CLIENT_ID`, `GF_OIDC_CLIENT_SECRET`, `ALERTMANAGER_WEBHOOK_URL` | Required | Operator | Required for observability deploy and alert routing |
| `/stacks/ai-interface` | `ARCH_PC_IP` | Required | Operator | Required for Open WebUI upstream reachability |
| GitHub `vars.*`/`secrets.*` bootstrap set | `INFISICAL_MACHINE_IDENTITY_ID`, `INFISICAL_PROJECT_ID`, `TFC_*`, `CLOUD_STATIC_RUNNER_LABEL`, `TFC_TOKEN`, `INFISICAL_TOKEN` | Required | Platform | Required for pipeline execution and handover stages |

### Steady-State / Optional

| Path | Variables | Requirement | Owner | Notes |
|------|-----------|-------------|-------|-------|
| `/management` | `PORTAINER_LICENSE_KEY` | Optional | Operator | Only needed for Portainer BE licensing |
| GitHub `vars.*` | Timeout/poll interval tunables (`TFC_PLAN_*`, `PORTAINER_ALLOWLIST_PROPAGATION_*`, etc.) | Optional | Operator | Operational tuning only; defaults exist |
| `/deployments` | `PORTAINER_WEBHOOK_URLS`, `WEBHOOK_URL_*` | Optional (manual use) | Platform | Auto-managed outputs from Terraform apply; consumed automatically by pipelines |
| `/stacks/management` | `PORTAINER_AUTOMATION_ALLOWED_CIDRS` | Optional (manual seed only) | Security | Auto-synced by policy pipeline; manual set only as temporary break-glass bridge |

### Detailed Path Reference

### `/infrastructure` — Global

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `BASE_DOMAIN` | Your registered domain name (e.g. `example.com`) | All stack composes except gateway (Traefik routing labels), scripts |
| `TZ` | IANA timezone (e.g. `America/New_York`, `Etc/UTC`) | All stacks, Pi-hole |
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard → My Profile → API Tokens → Create Token → Zone:DNS:Edit | Traefik (ACME DNS challenge), `cloudflare-dns.sh` |
| `ZONE_ID` | Cloudflare dashboard → select domain → Overview sidebar → Zone ID | `cloudflare-dns.sh` (also present in gateway `.env.tmpl` but not used by the compose) |
| `TAILSCALE_AUTH_KEY` | Tailscale admin → Settings → Keys → Generate auth key | Ansible provisioning (`tailscale up --authkey=...`) |

### `/management` — Portainer

| Variable | How to Get | Used By |
|----------|-----------|--------|
| `PORTAINER_URL` | Auto-written by Ansible `portainer_bootstrap` role (or manually set) | Human-facing Portainer URL (`https://portainer.<domain>`) behind Authelia |
| `PORTAINER_API_URL` | Auto-written by Ansible `portainer_bootstrap` role (or manually set) | Terraform Portainer provider `endpoint` (`https://portainer-api.<domain>`, API-only + IP allowlist) |
| `PORTAINER_API_KEY` | Auto-written by Ansible `portainer_bootstrap` role (or manually via Portainer → Access Tokens) | Terraform Portainer provider `api_key` |
| `PORTAINER_LICENSE_KEY` | Portainer BE license key (optional — leave unset for CE). Obtain from [Portainer pricing](https://www.portainer.io/pricing) or your account portal | Terraform `portainer_licenses` resource |

> **Note:** These credentials are written automatically by the Ansible `portainer_bootstrap` role during Phase 6 provisioning. Terraform reads `PORTAINER_API_URL` + `PORTAINER_API_KEY` to authenticate against the Portainer API. The resulting webhook URLs are written automatically to `/deployments` by Terraform.

### `/deployments` — Webhook URLs *(Terraform-managed)*

These secrets are **created and updated automatically** by the `portainer` Terraform module. Do not edit them manually.

The management stack (Portainer + Homarr) is deployed by Ansible, not Terraform, so it does not have a webhook URL here.

| Variable | Source | Used By |
|----------|--------|--------|
| `PORTAINER_WEBHOOK_URLS` | Comma-separated list of all stack webhook URLs | Manual bulk webhook trigger fallback |
| `WEBHOOK_URL_GATEWAY` | Individual webhook URL for the gateway stack | Direct API calls |
| `WEBHOOK_URL_AUTH` | Individual webhook URL for the auth stack | Direct API calls |
| `WEBHOOK_URL_NETWORK` | Individual webhook URL for the network stack | Direct API calls |
| `WEBHOOK_URL_OBSERVABILITY` | Individual webhook URL for the observability stack | Direct API calls |
| `WEBHOOK_URL_AI_INTERFACE` | Individual webhook URL for the ai-interface stack | Direct API calls |
| `WEBHOOK_URL_UPTIME` | Individual webhook URL for the uptime stack | Direct API calls |
| `WEBHOOK_URL_CLOUD` | Individual webhook URL for the cloud stack | Direct API calls |

### `/stacks/gateway` — Traefik

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `ACME_EMAIL` | Any valid email — Let's Encrypt sends expiry warnings here | Traefik cert resolver (`certificatesresolvers.letsencrypt.acme.email`) |
| `DOCKER_SOCKET_PROXY_URL` | Usually `tcp://socket-proxy:2375` (default in compose) — override only if using a remote socket proxy | Traefik `--providers.docker.endpoint` |

### `/stacks/identity` — Authelia

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `AUTHELIA_JWT_SECRET` | Generate: `openssl rand -base64 48` | Authelia JWT token signing |
| `AUTHELIA_SESSION_SECRET` | Generate: `openssl rand -base64 48` | Authelia session encryption |
| `POSTGRES_PASSWORD` | Generate: `openssl rand -base64 32` | Authelia ↔ PostgreSQL storage backend |
| `AUTHELIA_NOTIFIER_SMTP_USERNAME` | Your Gmail address (e.g. `user@gmail.com`) | SMTP authentication for 2FA enrollment emails |
| `AUTHELIA_NOTIFIER_SMTP_PASSWORD` | Gmail App Password (Google Account → Security → App passwords) | SMTP authentication |
| `AUTHELIA_NOTIFIER_SMTP_SENDER` | Display sender (e.g. `Authelia <noreply@yourdomain.com>`) | From address on notification emails |
| `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET` | Generate: `openssl rand -hex 32` | OIDC HMAC signing |
| `AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY` | Generate RSA key: `docker run --rm authelia/authelia authelia crypto certificate rsa generate --directory /tmp && cat /tmp/private.pem` (multi-line PEM) | OIDC JWT signing key |

### `/stacks/management` — Homarr + Portainer

| Variable | How to Get | Used By |
|----------|-----------|--------|
| `HOMARR_SECRET_KEY` | Generate: `openssl rand -hex 32` | Homarr `SECRET_ENCRYPTION_KEY` |
| `PORTAINER_ADMIN_PASSWORD` | Choose a strong password or generate: `openssl rand -base64 24` | Ansible `portainer_bootstrap` role — hashed to bcrypt at deploy time and passed to Portainer via `--admin-password`; plaintext used only for JWT auth to create API key |
| `PORTAINER_ADMIN_PASSWORD_HASH` | **Auto-generated and rewritten by Ansible on every bootstrap run** (`password_hash('bcrypt')`) and written to Infisical `/stacks/management` for Infisical Agent renders — do not set manually | Portainer `--admin-password` CLI flag (set in `docker-compose.yml`) |
| `PORTAINER_AUTOMATION_ALLOWED_CIDRS` | Auto-synced by the infrastructure orchestrator network policy sync job (or manually seeded before first sync) | Traefik `ipAllowList` middleware on `portainer-api.<domain>` |

### `/stacks/network` — Vaultwarden + Pi-hole

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `VW_DB_PASS` | Generate: `openssl rand -base64 32` | Vaultwarden + PostgreSQL (`DATABASE_URL`) |
| `VW_ADMIN_TOKEN` | Generate: `openssl rand -base64 48` — or use `vaultwarden` CLI to create an Argon2 hash | Vaultwarden `/admin` panel |
| `PIHOLE_PASSWORD` | Choose or generate: `openssl rand -base64 16` | Pi-hole web UI + Orbital Sync |

### `/stacks/observability` — Grafana + Alertmanager

| Variable | How to Get | Used By |
|----------|-----------|--------|
| `GF_OIDC_CLIENT_ID` | Choose a client ID (e.g., `grafana`) to define in Authelia's config | Grafana SSO setup |
| `GF_OIDC_CLIENT_SECRET` | Generate plaintext: `openssl rand -hex 32` (Must be hashed using `authelia crypto hash` for Authelia's config) | Grafana SSO setup |
| `ALERTMANAGER_WEBHOOK_URL` | Slack/Discord incoming webhook URL for alert notifications | Alertmanager webhook receiver |

### `/stacks/ai-interface` — Open WebUI

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `ARCH_PC_IP` | Tailscale IP or LAN IP of your machine running Ollama | Open WebUI `OLLAMA_BASE_URL` |

### `/cloud-provider/oci` — OCI Terraform

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `OCI_COMPARTMENT_OCID` | Compartments → View Details → Copy OCID | Resources grouping |
| `OCI_IMAGE_OCID` | Compute → Images → Custom/Canonical Image OCID | Terraform compute module |

### `/cloud-provider/gcp` — GCP Terraform

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `GCP_PROJECT_ID` | GCP Console → Top Navigation (e.g., `goodoldmeserver-123`) | Terraform Google provider `project` |

### GitHub Actions Variables & Secrets

While Infisical manages infrastructure and application secrets, a few bootstrap values must be stored directly in GitHub (Settings → Security → Secrets and variables → Actions) for CI/CD pipelines.

The workflow authenticates to Infisical via **OIDC** (not Universal Auth), so no client ID/secret pair is needed.

#### Variables (`vars.*`)

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `INFISICAL_MACHINE_IDENTITY_ID` | Infisical → Access Control → Machine Identities → OIDC Auth → Identity ID | `infra-orchestrator.yml` OIDC login |
| `INFISICAL_PROJECT_ID` | Infisical → Project Settings → Project ID | Terraform/Ansible workflows and webhook runner secret reads |
| `INFISICAL_SSH_CA_ID` | Infisical → SSH Management → SSH CA details | `infra-orchestrator.yml` ephemeral SSH cert signing |
| `TFC_ORGANIZATION` (or `TFC_ORG`) | Terraform Cloud organization slug | Infrastructure orchestrator + infrastructure validation Terraform Cloud API calls |
| `CLOUD_STATIC_RUNNER_LABEL` | Label of your static-egress private runner | Infrastructure orchestrator jobs that require deterministic egress + private reachability |
| `TFC_WORKSPACE_INFRA` | Terraform Cloud → Workspace name (`goodoldme-infra`) | Infra workspace apply (`terraform/infra`) |
| `TFC_WORKSPACE_PORTAINER` | Terraform Cloud → Workspace name (`goodoldme-portainer`) | Portainer workspace apply (`terraform/portainer-root`) |
| `TFC_INFRA_APPLY_WAIT_TIMEOUT_SECONDS` *(optional)* | Integer seconds (default `7200`) | Infra manual-confirm wait loop in infrastructure orchestrator |
| `TFC_PLAN_WAIT_TIMEOUT_SECONDS` *(optional)* | Integer seconds (default `7200`) | IaC validation speculative-plan wait timeout |
| `TFC_PLAN_POLL_INTERVAL_SECONDS` *(optional)* | Integer seconds (default `10`) | IaC validation speculative-plan polling interval |
| `PORTAINER_ALLOWLIST_PROPAGATION_TIMEOUT_SECONDS` *(optional)* | Integer seconds (default `420`) | Portainer allowlist propagation wait timeout |
| `PORTAINER_ALLOWLIST_PROPAGATION_POLL_INTERVAL_SECONDS` *(optional)* | Integer seconds (default `5`) | Portainer allowlist propagation polling interval |

#### Secrets (`secrets.*`)

| Variable | How to Get | Used By |
|----------|-----------|---------|
| `INFISICAL_TOKEN` (infra repo) | Infisical service token with project read/write scope for automation paths | Required by cloud-runner guard and local `terraform/portainer-root` apply path |
| `INFRA_REPO_DISPATCH_TOKEN` (stacks repo) | Fine-grained GitHub token with `contents:write` + repository dispatch access on this infra repo | `stacks/.github/workflows/stacks-dispatch-redeploy.yml` dispatches `stacks-redeploy-intent-v3` to this repo |
| `TFC_TOKEN` (infra repo) | Terraform Cloud Team/API token with workspace run access | `infra-orchestrator.yml` Terraform Cloud run/apply + state output inventory handover |

---

## Terraform Integration

Terraform is split into two workspaces/roots:

1. `goodoldme-infra` (`terraform/infra`) for OCI + GCP provisioning
2. `goodoldme-portainer` (`terraform/portainer-root`) for Portainer stack/webhook management

Both use the `infisical/infisical` provider with OIDC-backed environment credentials.

### Infra Workspace (`terraform/infra`)

Reads:

- `/security` (`SSH_CA_PUBLIC_KEY`)
- `/cloud-provider/oci` (`OCI_COMPARTMENT_OCID`, `OCI_IMAGE_OCID`)
- `/cloud-provider/gcp` (`GCP_PROJECT_ID`)

Creates:

- OCI infrastructure via `terraform/oci`
- GCP witness infrastructure via `terraform/gcp`

Exports:

- `oci_public_ips`
- `gcp_witness_ipv6`

### Portainer Workspace (`terraform/portainer-root`)

Reads:

- `/management` (`PORTAINER_API_URL`, `PORTAINER_API_KEY`, optional `PORTAINER_LICENSE_KEY`)

Creates (through `terraform/portainer` module):

- `portainer_stack` resources for application stacks
- Per-stack GitOps webhook URLs
- `/deployments/WEBHOOK_URL_*` + `/deployments/PORTAINER_WEBHOOK_URLS`

The default Git source for Portainer stacks is:

```hcl
repository_url = "https://github.com/JoseStud/stacks.git"
```

## Terraform → Portainer Integration

The `portainer` module reads stack definitions from `stacks/stacks.yaml` (fetched via `stacks_manifest_url`). Compose file paths remain **relative to the stacks repo root** (not `stacks/...` prefixed paths in this infra repo).

> **Boundary:** Ansible deploys the management stack (Portainer + Homarr) and writes `/management` credentials first. The `goodoldme-portainer` workspace depends on those credentials.

### Managed Stacks

The management stack is **not** in this list.

| Stack | Compose Path in stacks repo |
|-------|-----------------------------|
| gateway | `gateway/docker-compose.yml` |
| auth | `auth/docker-compose.yml` |
| network | `network/docker-compose.yml` |
| observability | `observability/docker-compose.yml` |
| ai-interface | `media/ai-interface/docker-compose.yml` |
| uptime | `uptime/docker-compose.yml` |
| cloud | `cloud/docker-compose.yml` |

### Adding a New Stack

1. Create the compose file in `github.com/JoseStud/stacks`
2. Add a new entry in `stacks/stacks.yaml` (`compose_path`, `portainer_managed`, `depends_on`, optional health checks)
3. Run `terraform -chdir=terraform/portainer-root apply` (or trigger `infra-orchestrator.yml` with `run_portainer_apply=true`)

## Private Webhook Automation

Webhook triggers run from stacks-repo workflows:

- `stacks/.github/workflows/stacks-ci.yml` (compose + manifest validation)
- `stacks/.github/workflows/stacks-dispatch-redeploy.yml` (payload planning + infra dispatch)

Flow:

1. Push to `main` in stacks repo
2. Private cloud static runner computes affected stacks from changed paths
3. Runner ignores non-deploy paths (for example docs/CI-only files)
4. Runner dispatches a unified event (`stacks-redeploy-intent-v3`) with schema `v3` payload to this infra repo
5. Infra `infra-orchestrator.yml` decides the ordered stages: secret validation -> optional Portainer apply -> optional config sync -> health-gated webhook redeploy

### `stacks-redeploy-intent-v3` Dispatch Contract

- Event type: `stacks-redeploy-intent-v3`
- Required `client_payload.schema_version`: `v3`
- Required `client_payload.stacks_sha`: commit SHA from stacks repo
- Required `client_payload.source_sha`: commit SHA from stacks repo workflow source
- Required `client_payload.changed_stacks`: JSON array of changed stack names
- Required `client_payload.config_stacks`: JSON array of config-sync stacks (`auth`, `observability`) or empty
- Required `client_payload.structural_change`: boolean
- Required `client_payload.reason`: `structural-change`, `manual-refresh`, or `content-change`
- Optional `client_payload.changed_paths`: JSON array of stack-relevant changed paths for audit
- Required `client_payload.source_repo`: source repository (`owner/repo`)
- Required `client_payload.source_run_id`: source workflow run id

## Infisical Agent (Docker Swarm)

The Infisical Agent runs on each Swarm node as a **systemd service**. It renders `.env` files from `.env.tmpl` templates and triggers stack redeploys on secret changes.

### Installing the Agent

1. **Download the Infisical CLI/Agent binary** (includes the agent mode):

```bash
# Install via the official install script
curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo bash
sudo apt-get install -y infisical
```

2. **Place the agent configuration** at `/etc/infisical/agent.yaml`. The reference config is maintained in this repo at `stacks/infisical-agent.yaml`:

```bash
sudo mkdir -p /etc/infisical
sudo cp stacks/infisical-agent.yaml /etc/infisical/agent.yaml
```

3. **Bootstrap Universal Auth credentials** — these are the only secrets stored outside Infisical. Edit the agent config to replace the `<INJECTED_BY_ANSIBLE>` placeholders with real values:

```bash
sudo nano /etc/infisical/agent.yaml
# Replace <INJECTED_BY_ANSIBLE> with actual client-id and client-secret
```

> Generate these credentials in Infisical: **Access Control → Machine Identities → Create Identity → Universal Auth**. Grant the identity read access to the project.

4. **Create the systemd unit file** at `/etc/systemd/system/infisical-agent.service`:

```ini
[Unit]
Description=Infisical Agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/infisical agent --config /etc/infisical/agent.yaml
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
```

5. **Enable and start the service:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now infisical-agent
```

6. **Verify the agent is running and templates are rendered:**

```bash
# Check service status
systemctl status infisical-agent

# Verify .env files have been created
ls -la /opt/stacks/*/.env

# Check agent logs for errors
journalctl -u infisical-agent --no-pager -n 50
```

### Stacks Directory on Host

The agent expects all stacks at `/opt/stacks/` on the host. This is typically a symlink or clone of the `stacks/` directory from this repository:

```bash
sudo ln -s /path/to/GoodOldMeServer/stacks /opt/stacks
# Or clone the stacks submodule directly:
sudo git clone https://github.com/JoseStud/stacks.git /opt/stacks
```

### Template Pattern

Every template pulls globals from `/infrastructure`, then stack-specific secrets from its own path:

```
# stacks/auth/.env.tmpl
{{- with secret "/infrastructure" }}
BASE_DOMAIN={{ .BASE_DOMAIN }}
TZ={{ .TZ }}
{{- end }}

{{- with secret "/stacks/identity" }}
AUTHELIA_JWT_SECRET={{ .AUTHELIA_JWT_SECRET }}
AUTHELIA_SESSION_SECRET={{ .AUTHELIA_SESSION_SECRET }}
POSTGRES_PASSWORD={{ .POSTGRES_PASSWORD }}
{{- end }}
```

Stacks that only need globals (uptime, cloud) have a single `/infrastructure` block.

> **Gateway exception:** The gateway `.env.tmpl` pulls `BASE_DOMAIN` and `ZONE_ID` from `/infrastructure` for completeness, but the gateway `docker-compose.yml` does not reference either variable. `CLOUDFLARE_API_TOKEN`, `ACME_EMAIL`, and `DOCKER_SOCKET_PROXY_URL` are the only variables the gateway compose actually substitutes.

### Template Inventory

| Stack | Template | Sources |
|-------|----------|---------|
| gateway | `stacks/gateway/.env.tmpl` | `/infrastructure` + `/stacks/gateway` |
| auth | `stacks/auth/.env.tmpl` | `/infrastructure` + `/stacks/identity` |
| management | `stacks/management/.env.tmpl` | `/infrastructure` + `/stacks/management` |
| network | `stacks/network/.env.tmpl` | `/infrastructure` + `/stacks/network` |
| observability | `stacks/observability/.env.tmpl` | `/infrastructure` + `/stacks/observability` |
| ai-interface | `stacks/media/ai-interface/.env.tmpl` | `/infrastructure` + `/stacks/ai-interface` |
| uptime | `stacks/uptime/.env.tmpl` | `/infrastructure` |
| cloud | `stacks/cloud/.env.tmpl` | `/infrastructure` |

### Agent Configuration

The agent config lives at `/etc/infisical/agent.yaml` (see `stacks/infisical-agent.yaml`). It contains one template entry per stack, each with:
- `source-path` → the `.env.tmpl` on disk
- `destination-path` → the rendered `.env`
- `polling-interval: 60s` → how often to check for changes
- `exec.command` → `docker stack deploy ...` to apply changes

### Workflow

1. Operator adds/updates a secret in the Infisical dashboard
2. The agent detects the change on its next polling interval (60s default)
3. Agent re-renders the `.env` file with the new value
4. Agent runs the `exec.command` to redeploy the stack with updated env vars

## infisical.json

The root `infisical.json` file stores the workspace ID for the Infisical CLI (used for local development/debugging):

```json
{
  "workspaceId": "<your-workspace-id>"
}
```

This file is intentionally kept in the repo (without secrets) so that `infisical` CLI commands work without passing `--projectId` every time.

## Adding a New Secret

1. **Create the secret** in the Infisical dashboard under the appropriate path
2. **Reference it in the template** — add a `{{- with secret "/path" }}` block to the stack's `.env.tmpl`
3. **Use it in the compose file** — reference via `${SECRET_NAME}` in the stack's `docker-compose.yml`
4. **Register the template** — add a new entry in `stacks/infisical-agent.yaml`
5. **The agent picks it up** — on the next poll, the `.env` is re-rendered and the stack redeployed

## Security Considerations

- Infisical Agent authenticates via Universal Auth (client ID + client secret) — these bootstrap credentials are the only secrets stored outside Infisical
- `.env` files are rendered on each node's filesystem — ensure `/opt/stacks/` has restricted permissions (`0750`)
- The `infisical.json` in the repo contains **only** the workspace ID (not sensitive)
- Terraform state contains decrypted secret values — use remote backends with encryption at rest
