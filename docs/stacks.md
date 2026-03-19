# Docker Swarm Stacks

This document describes every Docker Swarm stack, its services, deployment constraints, and inter-stack dependencies.

## Architecture

All stacks run on a 3-manager Docker Swarm cluster:

| Node | Provider | Role | Label |
|------|----------|------|-------|
| OCI Worker 1 | OCI (A1.Flex, 2 OCPU, 12 GB) | Manager + workloads | `location=cloud` |
| OCI Worker 2 | OCI (A1.Flex, 2 OCPU, 12 GB) | Manager + workloads | `location=cloud` |
| GCP Witness | GCP (e2-micro, 0.25 vCPU, 1 GB) | Manager (quorum only) | `role=witness` |

Most user-facing and stateful workloads are constrained to `node.labels.location == cloud` (OCI nodes). Exceptions are the manager-scoped `socket-proxy` and `portainer-server`, plus the global `portainer-agent`, `promtail`, and `node-exporter`.

## Stack Overview

| Stack | Services | Constraint | Depends On |
|-------|----------|------------|------------|
| **gateway** | traefik, socket-proxy | `traefik`: `location == cloud` (replicas: 2); `socket-proxy`: `node.role == manager` | — |
| **auth** | authelia, authelia-db | `location == cloud` | gateway |
| **management** | homarr, portainer-server, portainer-agent | `location == cloud` (homarr), `node.role == manager` (server), global (agent) | — (bootstrapped by Ansible Phase 6) |
| **network** | vaultwarden, vaultwarden-db, pihole-1, pihole-2, orbital-sync | `location == cloud` | gateway, auth |
| **observability** | prometheus, loki, promtail, node-exporter, grafana, alertmanager | `location == cloud` (stateful), global (promtail, node-exporter) | gateway, auth |
| **ai-interface** | open-webui, openclaw-gateway, openclaw-cli | `location == cloud` | gateway, auth |
| **uptime** | uptime-kuma | `location == cloud` | gateway, auth |
| **cloud** | filebrowser | `location == cloud` | gateway, auth |

## Deployment Order

0. **management** — Bootstrapped by Ansible Phase 6; not Portainer-managed
1. **gateway** — Traefik + docker-socket-proxy (uses the pre-created `traefik_proxy` overlay network)
2. **auth** — Authelia SSO (referenced as `authelia@docker` middleware by other stacks)
3. **All other Portainer-managed stacks** — No ordering constraints among themselves beyond `stacks/stacks.yaml` dependencies

See [Deployment Runbook](deployment-runbook.md) for step-by-step commands.

## Health Checks and Webhook Gate Behavior

Health-gated redeploy behavior is driven by `stacks/stacks.yaml` and `.github/scripts/stacks/trigger_webhooks_with_gates.sh`.

| Stack | Health endpoint | Expected status | Timeout | Dependency gate behavior | Post-trigger wait behavior |
|-------|------------------|-----------------|---------|--------------------------|----------------------------|
| `management` | N/A | N/A | N/A | Not Portainer-managed (`portainer_managed: false`); not part of webhook gate flow | N/A |
| `gateway` | `https://gateway-health.${BASE_DOMAIN}/healthz` | `200` | `300s` | No dependencies; can trigger first | Waits for gateway health endpoint after webhook trigger |
| `auth` | `https://auth.${BASE_DOMAIN}/api/health` | `200` | `300s` | Waits for `gateway` health before trigger | Waits for auth health endpoint after webhook trigger |
| `network` | N/A | N/A | N/A | Waits for dependency checks on `gateway` and `auth` first | No stack health URL configured; post-trigger health wait returns immediately |
| `observability` | N/A | N/A | N/A | Waits for dependency checks on `gateway` and `auth` first | No stack health URL configured; post-trigger health wait returns immediately |
| `ai-interface` | N/A | N/A | N/A | Waits for dependency checks on `gateway` and `auth` first | No stack health URL configured; post-trigger health wait returns immediately |
| `uptime` | N/A | N/A | N/A | Waits for dependency checks on `gateway` and `auth` first | No stack health URL configured; post-trigger health wait returns immediately |
| `cloud` | N/A | N/A | N/A | Waits for dependency checks on `gateway` and `auth` first | No stack health URL configured; post-trigger health wait returns immediately |

The gate script always checks dependency health before triggering a dependent stack webhook, then performs a post-trigger health wait for the triggered stack when a `healthcheck_url` exists.

## Shared Patterns

All stacks follow these conventions:

- **Network**: Every service with a web UI joins the `traefik_proxy` external overlay network
- **Routing**: Traefik labels on `deploy.labels` (not container labels) for Swarm compatibility
- **TLS**: `tls.certresolver=letsencrypt` on all HTTPS routers (ACME via Let's Encrypt)
- **Auth**: `authelia@docker` middleware on routes requiring SSO
- **Domains**: All hostnames use `${BASE_DOMAIN}` variable (injected by Infisical Agent)
- **Update policy**: `order: start-first` (zero-downtime rolling updates)
- **Image versioning**: Critical infrastructure and data services (Prometheus, Loki, Grafana, Vaultwarden, Authelia, socket-proxy, Alertmanager) are pinned to specific versions. Utility/dashboard services (Homarr, Pi-hole, Orbital Sync, OpenClaw) may use `:latest`
- **Resources**: Memory limits on every service to prevent OOM
- **Logging**: json-file driver with 10 MB rotation, 3 files max
- **Storage**: Persistent data on GlusterFS at `/mnt/swarm-shared/<stack>/`

## Stack Details

### Gateway

- **Traefik v3** — Reverse proxy, runs as 2 replicas on OCI workers
- **docker-socket-proxy** — Read-only proxy to the Docker socket (Traefik connects here instead of directly to `/var/run/docker.sock`). This service is manager-scoped, so it can land on either OCI node or the GCP witness.
- HTTP→HTTPS redirect on all traffic
- ACME certificates stored in a GlusterFS-backed bind-mount volume `traefik_acme` at `/mnt/swarm-shared/gateway/traefik_acme`, shared between both replicas
- Prometheus metrics exposed on a dedicated entrypoint (`:8082/metrics`)
- **No config files required** — fully configured via CLI flags

### Auth

- **Authelia** — SSO/2FA provider. Configuration bind-mounted from `/mnt/swarm-shared/auth/authelia/config`
- **Authelia-DB** — PostgreSQL 16 (Alpine) backend for Authelia's storage. Data stored in a bind-mounted Docker volume at `/mnt/swarm-shared/auth/authelia-db`. Connected to Authelia via the `authelia_internal` overlay network (not exposed to `traefik_proxy`)
- ForwardAuth middleware registered as `authelia@docker` — other stacks reference this for protected routes
- Default access policy: `two_factor` for all protected services
- OIDC provider configured for Grafana SSO (`client_id: grafana`)

**Config files** (in `stacks/auth/config/`):

| File | Purpose |
|------|---------|
| `configuration.yml` | Authelia main config: server, session, storage, auth backend, access control, OIDC provider, TOTP/WebAuthn, SMTP notifier. Synced to GlusterFS by Ansible `sync-configs`. |
| `users_database.yml` | Bootstrap placeholder file-based auth database. Seeded to GlusterFS only if missing. |
| `users_database.yml.tmpl` | Infisical Agent template that renders the real Authelia users database from `/stacks/identity/AUTHELIA_USERS_DATABASE_YAML` and syncs it to GlusterFS on the primary manager. |

**Additional Infisical secrets** (under `/stacks/identity`):

| Variable | How to Get |
|----------|-----------|
| `AUTHELIA_STORAGE_ENCRYPTION_KEY` | Generate: `openssl rand -base64 48` |
| `AUTHELIA_USERS_DATABASE_YAML` | Multi-line YAML for the full Authelia users database. Generate password hashes with `authelia crypto hash generate argon2` and store the resulting `users:` document in Infisical. |
| `AUTHELIA_NOTIFIER_SMTP_USERNAME` | Gmail address for SMTP |
| `AUTHELIA_NOTIFIER_SMTP_PASSWORD` | Gmail App Password (Settings → Security → App passwords) |
| `AUTHELIA_NOTIFIER_SMTP_SENDER` | e.g. `Authelia <noreply@example.com>` |
| `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET` | Generate: `openssl rand -hex 32` |
| `AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY` | Generate: `authelia crypto certificate rsa generate --directory /tmp && cat /tmp/private.pem` |
| `AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET` | Generate from `GF_OIDC_CLIENT_SECRET` with `authelia crypto hash generate argon2 --password '<GF_OIDC_CLIENT_SECRET value>'` |

### Management

- **Homarr** — Dashboard / homepage
- **Portainer** — Docker Swarm management UI (server + agent in global mode)

### Network

- **Vaultwarden** — Bitwarden-compatible password manager with PostgreSQL backend. Uses its own native authentication (master password + optional 2FA) without Authelia ForwardAuth to ensure compatibility with Bitwarden client apps (desktop, mobile, browser extension)
- **Pi-hole ×2** — DNS ad-blocking (node1 on OCI Worker 1, node2 on OCI Worker 2 via hostname constraint)
- **Orbital Sync** — Syncs Pi-hole configs between instances every 30 minutes

### Observability

- **Prometheus** — Metrics collection (15-day retention)
- **Loki** — Log aggregation (7-day retention, TSDB + filesystem storage)
- **Promtail** — Log shipper (global — runs on every node, Docker socket discovery)
- **Node Exporter** — Host metrics (global)
- **Grafana** — Dashboards and visualization (Authelia OIDC SSO, login form disabled)
- **Alertmanager** — Alert routing and notifications via webhook (Slack/Discord). Receives alerts from Prometheus based on defined rules (instance down, high memory/disk/CPU, Traefik error rates)

Data volumes are bind-mounted to GlusterFS for persistence and replication.

**Config files** (in `stacks/observability/config/`):

| File | GlusterFS Path | Purpose |
|------|---------------|---------|
| `prometheus.yml` | `/mnt/swarm-shared/observability/prometheus/prometheus.yml` | Scrape targets: self, node-exporter, traefik, loki |
| `alert-rules.yml` | `/mnt/swarm-shared/observability/prometheus/alert-rules.yml` | Alert rules: instance down, high memory/disk/CPU, Traefik error rates |
| `loki-config.yaml` | `/mnt/swarm-shared/observability/loki/loki-config.yaml` | Loki storage, schema, retention, compactor |
| `promtail.yml` | `/mnt/swarm-shared/observability/promtail/promtail.yml` | Docker SD log collection, label extraction, JSON pipeline |
| `alertmanager.yml` | `/mnt/swarm-shared/observability/alertmanager/alertmanager.yml` | Bootstrap placeholder config. Seeded to GlusterFS only if missing. |
| `alertmanager.yml.tmpl` | `/mnt/swarm-shared/observability/alertmanager/alertmanager.yml` | Infisical Agent template that renders the real Alertmanager routing and webhook receiver config from `/stacks/observability/ALERTMANAGER_WEBHOOK_URL` and syncs it to GlusterFS on the primary manager. |

### Media / AI Interface

- **Open WebUI** — LLM chat interface connecting to a remote Ollama instance
- **OpenClaw Gateway** — AI gateway proxy
- **OpenClaw CLI** — CLI tool (no web UI, no Traefik routing)

### Uptime

- **Uptime Kuma** — Status monitoring for all services

### Cloud

- **FileBrowser** — Web-based file manager for the GlusterFS shared volume

## Environment Variables

All compose files use `${BASE_DOMAIN}` for domain names and `${TZ}` for timezone. These globals live in `/infrastructure`.

For direct-deploy and break-glass workflows, the Infisical Agent renders host-side `.env` mirrors under `/opt/stacks/<stack>/.env`.

For Portainer-managed stacks, Terraform injects the same values into the Portainer stack definition via `portainer_stack.env`. Portainer does not read the host-rendered `/opt/stacks/<stack>/.env` files during normal GitOps redeploys.

Per-stack secrets are in their own Infisical paths:

| Stack | Template | Infisical Path | Stack-Specific Variables |
|-------|----------|---------------|--------------------------|
| gateway | `stacks/gateway/.env.tmpl` | `/stacks/gateway` | `CLOUDFLARE_API_TOKEN` (from `/infrastructure`), `ACME_EMAIL`, `DOCKER_SOCKET_PROXY_URL` |
| auth | `stacks/auth/.env.tmpl` | `/stacks/identity` | `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `POSTGRES_PASSWORD`, `AUTHELIA_STORAGE_ENCRYPTION_KEY`, `AUTHELIA_NOTIFIER_SMTP_USERNAME`, `AUTHELIA_NOTIFIER_SMTP_PASSWORD`, `AUTHELIA_NOTIFIER_SMTP_SENDER`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET` |
| auth | `stacks/auth/config/users_database.yml.tmpl` | `/stacks/identity` | `AUTHELIA_USERS_DATABASE_YAML` |
| management | `stacks/management/.env.tmpl` | `/stacks/management` | `HOMARR_SECRET_KEY`, `PORTAINER_ADMIN_PASSWORD_HASH` |
| network | `stacks/network/.env.tmpl` | `/stacks/network` | `VW_DB_PASS`, `VW_ADMIN_TOKEN`, `PIHOLE_PASSWORD` |
| observability | `stacks/observability/.env.tmpl` | `/stacks/observability` | `GF_OIDC_CLIENT_ID`, `GF_OIDC_CLIENT_SECRET`, `ALERTMANAGER_WEBHOOK_URL` |
| observability | `stacks/observability/config/alertmanager.yml.tmpl` | `/stacks/observability` | `ALERTMANAGER_WEBHOOK_URL` |
| ai-interface | `stacks/media/ai-interface/.env.tmpl` | `/stacks/ai-interface` | `ARCH_PC_IP` |
| uptime | `stacks/uptime/.env.tmpl` | — | *(globals only)* |
| cloud | `stacks/cloud/.env.tmpl` | — | *(globals only)* |

See [Infisical Workflow](infisical-workflow.md) for the full variable reference, variable ownership/mutability, and generation commands.

## Config File Sync

Some stacks require configuration files that are bind-mounted from GlusterFS at runtime. These config files live in the repo under `stacks/<stack>/config/`. Static files are synced to GlusterFS by Ansible `sync-configs`, while selected secret-backed templates are rendered by the Infisical Agent and copied to GlusterFS by runtime helpers:

```bash
# Sync all config files to GlusterFS
ansible-playbook -i ansible/inventory/terraform.yml ansible/playbooks/provision.yml --tags sync-configs
```

Stacks that are self-configuring (no config files needed): **gateway**, **management**, **network**, **media/ai-interface**, **uptime**, **cloud**.

## Host Runtime Sync

Host runtime assets are Ansible-managed. Use `phase7_runtime_sync` to mirror the trusted `stacks/` checkout to `/opt/stacks`, render `/etc/infisical/agent.yaml`, and refresh the local webhook helper/service on every node. The management stack template renders `/opt/stacks/management/.env` and runs a direct `docker stack deploy`. Portainer-managed stack `.env` templates are still rendered to `/opt/stacks/<stack>/.env` for break-glass direct deploys, but their normal stack environment lives in Portainer and is updated by Terraform rather than the on-node agent.

```bash
ansible-playbook -i ansible/inventory/terraform.yml ansible/playbooks/provision.yml --tags phase7_runtime_sync
```

## Adding a New Stack

1. Create `stacks/<name>/docker-compose.yml` following the shared patterns above
2. Add secrets to Infisical under `/stacks/<name>`
3. Create `.env.tmpl` for the Infisical Agent to render
4. If the stack needs config files, add them under `stacks/<name>/config/` and add a sync task to `ansible/roles/glusterfs/tasks/sync-configs.yml`
5. Register the stack in `stacks/infisical-agent.yaml` so host-sync-only template changes can update the runtime path
6. Run `ansible-playbook -i ansible/inventory/terraform.yml ansible/playbooks/provision.yml --tags phase7_runtime_sync` to converge `/opt/stacks` and the agent config
7. If the stack is Portainer-managed, add its env mapping in `terraform/portainer/main.tf` so Portainer receives the required compose variables from Infisical
8. Deploy: use direct `docker stack deploy` only for non-Portainer-managed stacks; otherwise let the normal Terraform + Portainer webhook automation own the deploy path
9. Update this document and the [Deployment Runbook](deployment-runbook.md)
