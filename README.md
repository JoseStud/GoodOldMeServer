# GoodOldMeServer

Personal homelab/cloud server infrastructure using a four-layer architecture:

1. **Terraform** provisions cloud resources across Oracle Cloud (2× Ampere A1.Flex workers) and Google Cloud (1× e2-micro Swarm witness)
2. **Ansible** bootstraps nodes through 7 phases: system user + storage → Docker → Tailscale mesh → GlusterFS → Docker Swarm → Portainer bootstrap → host runtime sync
3. **Docker Swarm** runs 8 stacks behind Traefik with Authelia SSO, using Infisical-rendered runtime env files and Portainer GitOps for the Portainer-managed stacks
4. **Infrastructure Orchestrator (GitHub Actions)** orchestrates secret validation → infra apply → inventory handover → Ansible bootstrap → Portainer apply → health-gated stack redeploy

## Prerequisites

- [Terraform](https://www.terraform.io/) >= 1.5.0
- [Ansible](https://docs.ansible.com/) with `cloud.terraform` collection
- [Tailscale](https://tailscale.com/) account with an auth key
- [Infisical](https://infisical.com/) account with project configured
- OCI free-tier account (Ampere A1 instances + block volumes)
- GCP free-tier account (e2-micro instance)
- SSH CA key pair for certificate-based authentication
- Terraform Cloud workspace variable for network policy:
  - `TF_VAR_network_access_policy` (JSON object with OCI SSH IPv4, GCP SSH IPv6, Portainer API allowlists)

## Quick Start

```bash
# 1. End-to-end orchestration (recommended)
# GitHub Actions: .github/workflows/infra-orchestrator.yml

# 2. Local fallback: provision cloud infrastructure
terraform -chdir=terraform/infra apply

# 3. Local fallback: bootstrap nodes end-to-end
ansible-playbook -i ansible/inventory/terraform.yml ansible/playbooks/provision.yml

# 4. Local fallback: create/update Portainer-managed stacks + webhooks
terraform -chdir=terraform/portainer-root apply

# 5. Break-glass direct docker stack deploys are documented separately
# See docs/deployment-runbook.md for the current host-synced /opt/stacks flow
```

Ansible Phase 6 bootstraps the `management` stack. The remaining Portainer-managed stacks are normally converged by `terraform/portainer-root` and redeployed through webhooks rather than direct `docker stack deploy` calls from this checkout.

For the full deployment procedure, see the [Deployment Runbook](docs/deployment-runbook.md).
For first-time pipeline setup, use the [Infrastructure Orchestrator Cutover Checklist](docs/meta-pipeline-cutover-checklist.md).
For the current GitHub Actions entry points, see the [Workflow Lifecycle](docs/workflow-lifecycle.md).
For workflow responsibilities, triggers, and reusable inputs/outputs, see [GitHub Actions Workflows](docs/github-actions-workflows.md).
For CI orchestration planning behavior, see the [CI Orchestrator Execution Rules](docs/ci-orchestrator-execution-rules.md).
For the canonical `plan_json` schema and consumption rules, see the [CI Plan Contract](docs/ci-plan-contract.md).

## Documentation

This project uses a centralized documentation structure to keep the code directories clean.

👉 **[Read the Documentation](docs/index.md)**
