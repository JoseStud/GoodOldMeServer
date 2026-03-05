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

### `.github/scripts/detect_iac_impact.sh`
- **Purpose**: Resolves IaC validation impact outputs from event context and path-filter booleans (Terraform roots, workspace matrix, ansible toggle, stacks SHA signal).
- **Parameters**:
  - Environment: `EVENT_NAME`, `GITHUB_OUTPUT`, `GITHUB_SHA_CURRENT`, optional `PUSH_BEFORE_SHA`
  - Environment booleans (from `dorny/paths-filter`): `IAC_WORKSPACE_INFRA`, `IAC_WORKSPACE_PORTAINER`, `IAC_ANSIBLE`, `IAC_STACKS_GITLINK_CHANGED`, `IAC_TF_INFRA`, `IAC_TF_OCI`, `IAC_TF_GCP`, `IAC_TF_PORTAINER_ROOT`, `IAC_TF_PORTAINER`
- **Example**: Invoked by `.github/workflows/iac-validation.yml` detect-impact job

### `.github/scripts/resolve_meta_context.sh`
- **Purpose**: Shared resolver for `meta-pipeline.yml` and `meta-pipeline-smoke.yml` that produces execution toggles and normalized context outputs.
- **Parameters**:
  - Environment: `EVENT_NAME`, `GITHUB_OUTPUT`, push vars (`PUSH_BEFORE`, `PUSH_SHA`), input vars, payload vars
  - Environment booleans (from `dorny/paths-filter`): `META_FILTER_APPLIED`, `META_INFRA_CHANGED`, `META_ANSIBLE_CHANGED`, `META_PORTAINER_CHANGED`
  - Optional behavior flag: `RESOLVE_STACKS_SHA_FROM_HEAD`
- **Example**: Invoked by meta pipeline resolve-context jobs

### `.github/scripts/build_network_access_policy.sh`
- **Purpose**: Builds canonical `network_access_policy` JSON from cloud runner dual-stack egress (`/32` IPv4 + `/128` IPv6) or an optional break-glass override.
- **Parameters**:
  - Environment: optional `BREAK_GLASS_POLICY_JSON` or `BREAK_GLASS_POLICY_FILE`
  - Network dependencies: outbound access to `api.ipify.org` and `api64.ipify.org` when no break-glass override is supplied
- **Example**: `BREAK_GLASS_POLICY_JSON='{"oci_ssh":{"enabled":true,"source_ranges":["203.0.113.10/32"]},"gcp_ssh":{"enabled":true,"source_ranges":["2001:db8::/128"]},"portainer_api":{"source_ranges":["203.0.113.10/32","2001:db8::/128"]}}' .github/scripts/build_network_access_policy.sh`

### `.github/scripts/sync_network_access_policy.sh`
- **Purpose**: Atomically syncs network policy to Terraform Cloud (`TF_VAR_network_access_policy`) and Infisical (`PORTAINER_AUTOMATION_ALLOWED_CIDRS`) with read-after-write verification on both targets.
- **Parameters**:
  - Environment: `NETWORK_ACCESS_POLICY_JSON`, `TFC_TOKEN`, `TFC_ORGANIZATION`, `TFC_WORKSPACE_INFRA`, `INFISICAL_PROJECT_ID`
- **Example**: `NETWORK_ACCESS_POLICY_JSON='{"oci_ssh":{"enabled":true,"source_ranges":["203.0.113.10/32"]},"gcp_ssh":{"enabled":true,"source_ranges":["2001:db8::/128"]},"portainer_api":{"source_ranges":["203.0.113.10/32","2001:db8::/128"]}}' .github/scripts/sync_network_access_policy.sh`

### `.github/scripts/preflight_network_access.sh`
- **Purpose**: Fail-closed preflight gate that validates runner egress against policy and verifies SSH/Portainer reachability before network-dependent jobs.
- **Parameters**:
  - Environment: `NETWORK_ACCESS_POLICY_JSON`
  - Optional environment toggles: `RUN_ANSIBLE`, `RUN_CONFIG`, `RUN_HEALTH`, `RUN_PORTAINER`, `PORTAINER_API_URL`, `INVENTORY_FILE`
- **Example**: `RUN_ANSIBLE=true INVENTORY_FILE=inventory-ci.yml NETWORK_ACCESS_POLICY_JSON='{"oci_ssh":{"enabled":true,"source_ranges":["203.0.113.10/32"]},"gcp_ssh":{"enabled":true,"source_ranges":["2001:db8::/128"]},"portainer_api":{"source_ranges":["203.0.113.10/32","2001:db8::/128"]}}' .github/scripts/preflight_network_access.sh`

### `.github/scripts/wait_for_portainer_allowlist_propagation.sh`
- **Purpose**: Polls `PORTAINER_API_URL/api/system/status` and blocks until `PORTAINER_AUTOMATION_ALLOWED_CIDRS` propagation allows traffic from the current runner.
- **Parameters**:
  - Environment: `PORTAINER_API_URL`
  - Optional: `WAIT_TIMEOUT_SECONDS`, `POLL_INTERVAL_SECONDS`
- **Example**: `PORTAINER_API_URL=https://portainer-api.example.com .github/scripts/wait_for_portainer_allowlist_propagation.sh`

### `.github/scripts/assert_tfc_workspace_local_mode.sh`
- **Purpose**: Hard-checks Terraform Cloud workspace setting `operations=false` via TFC API before local Portainer Terraform plan/apply.
- **Parameters**:
  - Environment: `TFC_TOKEN`, `TFC_ORGANIZATION`, `TFC_WORKSPACE`
- **Example**: `TFC_TOKEN=... TFC_ORGANIZATION=my-org TFC_WORKSPACE=goodoldme-portainer .github/scripts/assert_tfc_workspace_local_mode.sh`

### `scripts/archive/portainer-deploy.sh` *(archived)*
- **Purpose**: Legacy script that pushed `.env` files to Portainer via its REST API. Replaced by native GitOps webhooks.
- **Parameters**: `$1` `<STACK_NAME>`, `$2` `<ENV_FILE_PATH>`, env `BASE_DOMAIN`, `PORTAINER_TOKEN`, `ENDPOINT_ID`

### `scripts/archive/update_deploy.py` *(archived)*
- **Purpose**: Utility script that scans all `docker-compose.yml` files and injects `update_config: order: start-first` into every service's `deploy:` block. Used as a one-time migration tool to ensure zero-downtime rolling updates across all stacks.
- **Parameters**: None (hardcoded list of compose files)
- **Example**: `python3 scripts/archive/update_deploy.py`

> For deployment commands, see the [Deployment Runbook](deployment-runbook.md). For Ansible operations, see the [Ansible docs](ansible.md#running-ansible).
