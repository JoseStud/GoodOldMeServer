# Docker Swarm Stacks

This document describes every Docker Swarm stack, its services, deployment constraints, and inter-stack dependencies.

## Architecture

All stacks run on a 3-manager Docker Swarm cluster:

| Node | Provider | Role | Label |
|------|----------|------|-------|
| OCI Worker 1 | OCI (A1.Flex, 2 OCPU, 12 GB) | Manager + workloads | `location=cloud` |
| OCI Worker 2 | OCI (A1.Flex, 2 OCPU, 12 GB) | Manager + workloads | `location=cloud` |
| GCP Witness | GCP (e2-micro, 0.25 vCPU, 1 GB) | Manager (quorum only) | `role=witness` |

All workloads are constrained to `node.labels.location == cloud` (OCI nodes). The GCP witness only participates in Raft consensus.

## Stack Overview

| Stack | Services | Constraint | Depends On |
|-------|----------|------------|------------|
| **gateway** | traefik, socket-proxy | `location == cloud` (replicated: 2) | — |
| **auth** | authelia, authelia-db | `location == cloud` | gateway |
| **management** | homarr, portainer-server, portainer-agent | `location == cloud` (homarr), `node.role == manager` (server), global (agent) | gateway, auth |
| **network** | vaultwarden, vaultwarden-db, pihole-1, pihole-2, orbital-sync | `location == cloud` | gateway, auth |
| **observability** | prometheus, loki, promtail, node-exporter, grafana, alertmanager | `location == cloud` (stateful), global (promtail, node-exporter) | gateway, auth |
| **media** | open-webui, openclaw-gateway, openclaw-cli | `location == cloud` | gateway, auth |
| **uptime** | uptime-kuma | `location == cloud` | gateway, auth |
| **cloud** | filebrowser | `location == cloud` | gateway |

## Deployment Order

1. **gateway** — Traefik + docker-socket-proxy (creates the `traefik_proxy` overlay network)
2. **auth** — Authelia SSO (referenced as `authelia@docker` middleware by other stacks)
3. **All other stacks** — No ordering constraints among themselves

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
- **docker-socket-proxy** — Read-only proxy to the Docker socket (Traefik connects here instead of directly to `/var/run/docker.sock`)
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

**Config files** (in `stacks/auth/config/`, synced to GlusterFS by Ansible):

| File | Purpose |
|------|---------|
| `configuration.yml` | Authelia main config: server, session, storage, auth backend, access control, OIDC provider, TOTP/WebAuthn, SMTP notifier |
| `users_database.yml` | File-based auth backend — user accounts with argon2id-hashed passwords |

**Additional Infisical secrets** (under `/stacks/identity`):

| Variable | How to Get |
|----------|-----------|
| `AUTHELIA_NOTIFIER_SMTP_USERNAME` | Gmail address for SMTP |
| `AUTHELIA_NOTIFIER_SMTP_PASSWORD` | Gmail App Password (Settings → Security → App passwords) |
| `AUTHELIA_NOTIFIER_SMTP_SENDER` | e.g. `Authelia <noreply@example.com>` |
| `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET` | Generate: `openssl rand -hex 32` |
| `AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY` | Generate: `authelia crypto certificate rsa generate --directory /tmp && cat /tmp/private.pem` |

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

**Config files** (in `stacks/observability/config/`, synced to GlusterFS by Ansible):

| File | GlusterFS Path | Purpose |
|------|---------------|---------|
| `prometheus.yml` | `/mnt/swarm-shared/observability/prometheus/prometheus.yml` | Scrape targets: self, node-exporter, traefik, loki |
| `alert-rules.yml` | `/mnt/swarm-shared/observability/prometheus/alert-rules.yml` | Alert rules: instance down, high memory/disk/CPU, Traefik error rates |
| `loki-config.yaml` | `/mnt/swarm-shared/observability/loki/loki-config.yaml` | Loki storage, schema, retention, compactor |
| `promtail.yml` | `/mnt/swarm-shared/observability/promtail/promtail.yml` | Docker SD log collection, label extraction, JSON pipeline |
| `alertmanager.yml` | `/mnt/swarm-shared/observability/alertmanager/alertmanager.yml` | Alertmanager routing, webhook receiver, inhibition rules |

### Media / AI Interface

- **Open WebUI** — LLM chat interface connecting to a remote Ollama instance
- **OpenClaw Gateway** — AI gateway proxy
- **OpenClaw CLI** — CLI tool (no web UI, no Traefik routing)

### Uptime

- **Uptime Kuma** — Status monitoring for all services

### Cloud

- **FileBrowser** — Web-based file manager for the GlusterFS shared volume

## Environment Variables

All compose files use `${BASE_DOMAIN}` for domain names and `${TZ}` for timezone. These globals live in `/infrastructure` and are injected into every stack's `.env` by the Infisical Agent — no duplication needed.

Per-stack secrets are in their own Infisical paths:

| Stack | Template | Infisical Path | Stack-Specific Variables |
|-------|----------|---------------|--------------------------|
| gateway | `stacks/gateway/.env.tmpl` | `/stacks/gateway` | `CLOUDFLARE_API_TOKEN` (from `/infrastructure`), `ACME_EMAIL`, `DOCKER_SOCKET_PROXY_URL` |
| auth | `stacks/auth/.env.tmpl` | `/stacks/identity` | `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `POSTGRES_PASSWORD`, `AUTHELIA_NOTIFIER_SMTP_USERNAME`, `AUTHELIA_NOTIFIER_SMTP_PASSWORD`, `AUTHELIA_NOTIFIER_SMTP_SENDER`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET`, `AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY` |
| management | `stacks/management/.env.tmpl` | `/stacks/management` | `HOMARR_SECRET_KEY` |
| network | `stacks/network/.env.tmpl` | `/stacks/network` | `VW_DB_PASS`, `VW_ADMIN_TOKEN`, `PIHOLE_PASSWORD` |
| observability | `stacks/observability/.env.tmpl` | `/stacks/observability` | `GF_OIDC_CLIENT_ID`, `GF_OIDC_CLIENT_SECRET`, `ALERTMANAGER_WEBHOOK_URL` |
| ai-interface | `stacks/media/ai-interface/.env.tmpl` | `/stacks/ai-interface` | `ARCH_PC_IP` |
| uptime | `stacks/uptime/.env.tmpl` | — | *(globals only)* |
| cloud | `stacks/cloud/.env.tmpl` | — | *(globals only)* |

See [Infisical Workflow](infisical-workflow.md) for the full variable reference, variable ownership/mutability, and generation commands.

## Config File Sync

Some stacks require configuration files that are bind-mounted from GlusterFS at runtime. These config files live in the repo under `stacks/<stack>/config/` and are synced to GlusterFS by Ansible:

```bash
# Sync all config files to GlusterFS
ansible-playbook playbooks/provision.yml --tags sync-configs
```

Stacks that are self-configuring (no config files needed): **gateway**, **management**, **network**, **media/ai-interface**, **uptime**, **cloud**.

## Adding a New Stack

1. Create `stacks/<name>/docker-compose.yml` following the shared patterns above
2. Add secrets to Infisical under `/stacks/<name>`
3. Create `.env.tmpl` for the Infisical Agent to render
4. If the stack needs config files, add them under `stacks/<name>/config/` and add a sync task to `ansible/roles/glusterfs/tasks/sync-configs.yml`
5. Deploy: `docker stack deploy -c stacks/<name>/docker-compose.yml <name>`
6. Update this document and the [Deployment Runbook](deployment-runbook.md)
