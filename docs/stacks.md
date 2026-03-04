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
| **gateway** | traefik, socket-proxy | `node.role == manager` (global) | — |
| **auth** | authelia, authelia-db | `location == cloud` | gateway |
| **management** | homarr, portainer-server, portainer-agent | `location == cloud` (homarr), `node.role == manager` (server), global (agent) | gateway, auth |
| **network** | vaultwarden, vaultwarden-db, pihole-1, pihole-2, orbital-sync | `location == cloud` | gateway, auth |
| **observability** | prometheus, loki, promtail, node-exporter, grafana | `location == cloud` (stateful), global (promtail, node-exporter) | gateway, auth |
| **media** | open-webui, openclaw-gateway, openclaw-cli | `location == cloud` | gateway, auth |
| **uptime** | uptime-kuma | `location == cloud` | gateway, auth |
| **cloud** | filebrowser | `location == cloud` | gateway |

## Deployment Order

1. **gateway** — Traefik + docker-socket-proxy (creates the `traefik_proxy` overlay network)
2. **auth** — Authelia SSO (referenced as `authelia@docker` middleware by other stacks)
3. **All other stacks** — No ordering constraints among themselves

See [Deployment Runbook](deployment-runbook.md) for step-by-step commands.

## Shared Patterns

All stacks follow these conventions:

- **Network**: Every service with a web UI joins the `traefik_proxy` external overlay network
- **Routing**: Traefik labels on `deploy.labels` (not container labels) for Swarm compatibility
- **TLS**: `tls.certresolver=letsencrypt` on all HTTPS routers (ACME via Let's Encrypt)
- **Auth**: `authelia@docker` middleware on routes requiring SSO
- **Domains**: All hostnames use `${BASE_DOMAIN}` variable (injected by Infisical Agent)
- **Update policy**: `order: start-first` (zero-downtime rolling updates)
- **Resources**: Memory limits on every service to prevent OOM
- **Logging**: json-file driver with 10 MB rotation, 3 files max
- **Storage**: Persistent data on GlusterFS at `/mnt/swarm-shared/<stack>/`

## Stack Details

### Gateway

- **Traefik v3** — Reverse proxy, runs globally on all managers
- **docker-socket-proxy** — Read-only proxy to the Docker socket (Traefik connects here instead of directly to `/var/run/docker.sock`)
- HTTP→HTTPS redirect on all traffic
- ACME certificates stored in a named Docker volume `traefik_acme` (local driver, mounted at `/etc/traefik/acme` inside the container)

### Auth

- **Authelia** — SSO/2FA provider. Configuration bind-mounted from `/mnt/swarm-shared/auth/authelia/config`
- **Authelia-DB** — PostgreSQL 16 (Alpine) backend for Authelia's storage. Data stored in a bind-mounted Docker volume at `/mnt/swarm-shared/auth/authelia-db`. Connected to Authelia via the `authelia_internal` overlay network (not exposed to `traefik_proxy`)
- ForwardAuth middleware registered as `authelia@docker` — other stacks reference this for protected routes

### Management

- **Homarr** — Dashboard / homepage
- **Portainer** — Docker Swarm management UI (server + agent in global mode)

### Network

- **Vaultwarden** — Bitwarden-compatible password manager with PostgreSQL backend
- **Pi-hole ×2** — DNS ad-blocking (node1 on OCI Worker 1, node2 on OCI Worker 2 via hostname constraint)
- **Orbital Sync** — Syncs Pi-hole configs between instances every 30 minutes

### Observability

- **Prometheus** — Metrics collection (15-day retention)
- **Loki** — Log aggregation
- **Promtail** — Log shipper (global — runs on every node)
- **Node Exporter** — Host metrics (global)
- **Grafana** — Dashboards and visualization

Data volumes are bind-mounted to GlusterFS for persistence and replication.

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
| auth | `stacks/auth/.env.tmpl` | `/stacks/identity` | `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `POSTGRES_PASSWORD` |
| management | `stacks/management/.env.tmpl` | `/stacks/management` | `HOMARR_SECRET_KEY` |
| network | `stacks/network/.env.tmpl` | `/stacks/network` | `VW_DB_PASS`, `VW_ADMIN_TOKEN`, `PIHOLE_PASSWORD` |
| observability | `stacks/observability/.env.tmpl` | `/stacks/observability` | `GF_OIDC_CLIENT_ID`, `GF_OIDC_CLIENT_SECRET` |
| ai-interface | `stacks/media/ai-interface/.env.tmpl` | `/stacks/ai-interface` | `ARCH_PC_IP` |
| uptime | `stacks/uptime/.env.tmpl` | — | *(globals only)* |
| cloud | `stacks/cloud/.env.tmpl` | — | *(globals only)* |

See [Infisical Workflow](infisical-workflow.md) for the full variable reference with generation commands.

## Adding a New Stack

1. Create `stacks/<name>/docker-compose.yml` following the shared patterns above
2. Add secrets to Infisical under `/stacks/<name>`
3. Create `.env.tmpl` for the Infisical Agent to render
4. Deploy: `docker stack deploy -c stacks/<name>/docker-compose.yml <name>`
5. Update this document and the [Deployment Runbook](deployment-runbook.md)
