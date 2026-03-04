# Scripts & Utilities

This section details helper scripts stored within the `scripts/` folder and CI automation scripts under `.github/scripts/`.

## Overview

Scripts in this repository perform operational tasks, run CI/CD automations, wrapper configurations, or manual operations that sit outside standard Ansible or Terraform workflows.

## Catalog

| Column | Description |
|--------|-------------|
| **Script** | Filename and path |
| **Purpose** | What the script does |
| **Parameters** | Required arguments or environment variables |
| **Example** | Usage example |

### `scripts/cloudflare-dns.sh`
- **Purpose**: Creates or updates a Cloudflare DNS A record using API v4. Subdomain is automatically generated using the Stack Name and Base Domain.
- **Parameters**: 
  - `$1`: `<STACK_NAME>`
  - `$2`: `<IP_ADDRESS>`
  - Environment: `ZONE_ID`, `CLOUDFLARE_API_TOKEN`, `BASE_DOMAIN` (from Infisical `/infrastructure`)
- **Example**: `./scripts/cloudflare-dns.sh portainer 192.168.1.50`

### `scripts/portainer-webhook.sh`
- **Purpose**: Triggers Portainer GitOps webhooks to redeploy stacks from trusted private automation sources. Each stack is linked to the Git repository in Portainer with "Enable Webhook" — hitting the webhook URL tells Portainer to pull the latest Compose files and redeploy. No API key or endpoint ID required.
- **Parameters**: 
  - Positional args: one or more webhook URLs
  - Or environment: `WEBHOOK_URLS` (comma-separated list of Portainer webhook URLs)
- **Example (positional)**: `./scripts/portainer-webhook.sh https://portainer-api.example.com/api/webhooks/<uuid>`
- **Example (env var)**: `WEBHOOK_URLS="https://portainer-api.example.com/api/webhooks/<uuid1>,https://portainer-api.example.com/api/webhooks/<uuid2>" ./scripts/portainer-webhook.sh`

### `.github/scripts/render_inventory_from_tfc_outputs.sh`
- **Purpose**: Fetches Terraform Cloud workspace outputs (`oci_public_ips`, `gcp_witness_ipv6`) and renders deterministic `inventory-ci.yml` for GitHub Actions handover jobs.
- **Parameters**:
  - `$1`: `<TFC_WORKSPACE_NAME>`
  - `$2`: Optional output file path (default: `inventory-ci.yml`)
  - Environment: `TFC_TOKEN`, `TFC_ORGANIZATION`, optional `TFC_API_URL`
- **Example**: `TFC_TOKEN=... TFC_ORGANIZATION=my-org .github/scripts/render_inventory_from_tfc_outputs.sh goodoldme-infra`

### `.github/scripts/trigger_webhooks_with_gates.sh`
- **Purpose**: Triggers Portainer stack webhooks with dependency-aware health gates from `stacks/stacks.yaml` (for example, wait for Gateway health before Auth redeploy).
- **Parameters**:
  - `$1`: Manifest path (for example `stacks/stacks.yaml`)
  - `$2`: Optional `changed_stacks` CSV (or `STACKS_CSV` env var)
  - Environment: `WEBHOOK_URL_*` from Infisical `/deployments`, `BASE_DOMAIN` for templated health URLs
- **Example**: `STACKS_CSV="gateway,auth" .github/scripts/trigger_webhooks_with_gates.sh stacks/stacks.yaml`

### `scripts/archive/portainer-deploy.sh` *(archived)*
- **Purpose**: Legacy script that pushed `.env` files to Portainer via its REST API. Replaced by native GitOps webhooks.
- **Parameters**: `$1` `<STACK_NAME>`, `$2` `<ENV_FILE_PATH>`, env `BASE_DOMAIN`, `PORTAINER_TOKEN`, `ENDPOINT_ID`

### `scripts/archive/update_deploy.py` *(archived)*
- **Purpose**: Utility script that scans all `docker-compose.yml` files and injects `update_config: order: start-first` into every service's `deploy:` block. Used as a one-time migration tool to ensure zero-downtime rolling updates across all stacks.
- **Parameters**: None (hardcoded list of compose files)
- **Example**: `python3 scripts/archive/update_deploy.py`

> For deployment commands, see the [Deployment Runbook](deployment-runbook.md). For Ansible operations, see the [Ansible docs](ansible.md#running-ansible).
