# GoodOldMeServer

Personal homelab/cloud server infrastructure using a three-tier architecture:

1. **Terraform** provisions cloud resources across Oracle Cloud (2× Ampere A1.Flex workers) and Google Cloud (1× e2-micro Swarm witness)
2. **Ansible** bootstraps nodes through 5 phases: system user → Docker → Tailscale mesh → GlusterFS (replica-3-arbiter-1) → Docker Swarm (3-manager cluster)
3. **Docker Swarm** stacks deploy application workloads (8 stacks) behind Traefik reverse proxy with Authelia SSO, using Infisical for secret management

## Prerequisites

- [Terraform](https://www.terraform.io/) >= 1.5.0
- [Ansible](https://docs.ansible.com/) with `cloud.terraform` collection
- [Tailscale](https://tailscale.com/) account with OAuth client credentials
- [Infisical](https://infisical.com/) account with project configured
- OCI free-tier account (Ampere A1 instances + block volumes)
- GCP free-tier account (e2-micro instance)
- SSH CA key pair for certificate-based authentication

## Quick Start

```bash
# 1. Provision cloud infrastructure
cd terraform && terraform apply

# 2. Bootstrap nodes (Docker, Tailscale, GlusterFS, Swarm)
cd ../ansible && ansible-playbook -i inventory/terraform.yml playbooks/provision.yml

# 3. Deploy stacks (see deployment runbook for full procedure)
docker stack deploy -c stacks/gateway/docker-compose.yml gateway
docker stack deploy -c stacks/auth/docker-compose.yml auth
# ... remaining stacks in any order
```

For the full deployment procedure, see the [Deployment Runbook](docs/deployment-runbook.md).

## Documentation

This project uses a centralized documentation structure to keep the code directories clean.

👉 **[Read the Documentation](docs/index.md)**
