# Scripts & Utilities

This section details helper scripts stored within the `scripts/` folder.

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
- **Purpose**: Triggers Portainer GitOps webhooks to redeploy stacks. Each stack is linked to the Git repository in Portainer with "Enable Webhook" — hitting the webhook URL tells Portainer to pull the latest Compose files and redeploy. No API key or endpoint ID required.
- **Parameters**: 
  - Positional args: one or more webhook URLs
  - Or environment: `WEBHOOK_URLS` (comma-separated list of Portainer webhook URLs)
- **Example (positional)**: `./scripts/portainer-webhook.sh https://portainer.example.com/api/webhooks/<uuid>`
- **Example (env var)**: `WEBHOOK_URLS="https://portainer.example.com/api/webhooks/<uuid1>,https://portainer.example.com/api/webhooks/<uuid2>" ./scripts/portainer-webhook.sh`

### `scripts/archive/portainer-deploy.sh` *(archived)*
- **Purpose**: Legacy script that pushed `.env` files to Portainer via its REST API. Replaced by native GitOps webhooks.
- **Parameters**: `$1` `<STACK_NAME>`, `$2` `<ENV_FILE_PATH>`, env `BASE_DOMAIN`, `PORTAINER_TOKEN`, `ENDPOINT_ID`

> For deployment commands, see the [Deployment Runbook](deployment-runbook.md). For Ansible operations, see the [Ansible docs](ansible.md#running-ansible).
