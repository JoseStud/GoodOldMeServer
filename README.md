# GoodOldMeServer

Personal homelab/cloud server infrastructure using a three-tier architecture:

1. **Terraform** provisions cloud resources across Oracle Cloud (2× Ampere A1.Flex workers) and Google Cloud (1× e2-micro Swarm witness)
2. **Ansible** bootstraps nodes through 5 phases: system user → Docker → Tailscale mesh → GlusterFS (replica-3-arbiter-1) → Docker Swarm (3-manager cluster)
3. **Docker Swarm** stacks deploy application workloads (8 stacks) behind Traefik reverse proxy with Authelia SSO, using Infisical for secret management
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

# 3. Local fallback: bootstrap nodes (Docker, Tailscale, GlusterFS, Swarm)
ansible-playbook -i ansible/inventory/terraform.yml ansible/playbooks/provision.yml

# 4. Local fallback: create Portainer-managed GitOps stacks + webhooks
terraform -chdir=terraform/portainer-root apply

# 5. Deploy stacks (see deployment runbook for full procedure)
docker stack deploy -c stacks/gateway/docker-compose.yml gateway
docker stack deploy -c stacks/auth/docker-compose.yml auth
# ... remaining stacks in any order
```

For the full deployment procedure, see the [Deployment Runbook](docs/deployment-runbook.md).
For first-time pipeline setup, use the [Infrastructure Orchestrator Cutover Checklist](docs/meta-pipeline-cutover-checklist.md).
For CI change-detection behavior, see the [CI Impact Rules](docs/ci-impact-rules.md).
For CI plan schema and projection rules, see the [CI Plan Contract](docs/ci-plan-contract.md).

## Documentation

This project uses a centralized documentation structure to keep the code directories clean.

👉 **[Read the Documentation](docs/index.md)**
