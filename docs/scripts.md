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

### `scripts/portainer-deploy.sh`
- **Purpose**: Automates stack deployment to a Portainer instance by updating the stack's environment variables.
- **Parameters**: 
  - `$1`: `<STACK_NAME>`
  - `$2`: `<ENV_FILE_PATH>`
  - Environment: `PORTAINER_URL`, `PORTAINER_TOKEN`, `ENDPOINT_ID` (from Infisical `/management`)
- **Example**: `./scripts/portainer-deploy.sh my_stack .env`

> For deployment commands, see the [Deployment Runbook](deployment-runbook.md). For Ansible operations, see the [Ansible docs](ansible.md#running-ansible).
