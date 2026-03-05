# GoodOldMeServer Documentation

Welcome to the centralized GoodOldMeServer documentation. This repository manages the infrastructure, configuration, and workloads for the GoodOldMeServer environment using a three-tier architecture approach:

1. **Infrastructure Provisioning** — Terraform provisions cloud resources across OCI (2× Ampere A1 workers) and GCP (1× e2-micro Swarm witness)
2. **Configuration Management** — Ansible bootstraps nodes: system users, Docker, Tailscale mesh networking, GlusterFS distributed storage, and a 3-manager Docker Swarm cluster
3. **Application Workloads** — Docker Swarm stacks with Infisical-managed secrets, routed through Traefik reverse proxy with Authelia SSO
4. **Meta Pipeline** — GitHub Actions orchestrates secret validation, Terraform apply, inventory handover, Ansible bootstrap, Portainer apply, and health-gated webhook redeploys

> **Note:** The `stacks/` directory is a [Git submodule](https://github.com/JoseStud/stacks) tracking the `main` branch. Submodule update PRs are managed by Dependabot (`gitsubmodule` ecosystem).

## Start Here (Cutover + Ownership)

If you are bootstrapping or validating CI/CD for the first time, read these first:

1. [**Meta-Pipeline Cutover Checklist**](meta-pipeline-cutover-checklist.md) — required GitHub variables/secrets, Terraform workspace settings, and first-run sequence.
2. [**Infisical Workflow**](infisical-workflow.md#variable-ownership--mutability) — which variables are operator-managed vs auto-managed by Ansible, Terraform, or the meta-pipeline.
3. [**Deployment Runbook Prerequisites**](deployment-runbook.md#prerequisites) — operational readiness checks before deploy/apply actions.

## High-Level Architecture

```mermaid
flowchart TD
    subgraph IaC [Infrastructure Provisioning — Terraform]
        TFI[Infra Root<br/>terraform/infra]
        TFP[Portainer Root<br/>terraform/portainer-root]
        INF_TF[Infisical Provider]
        GCP[GCP Module<br/>VPC + e2-micro witness]
        OCI[OCI Module<br/>VCN + 2× A1.Flex workers<br/>+ block volumes + NSGs]
        PTN[Portainer Module<br/>GitOps stacks + webhooks]
        TFI --> INF_TF
        TFP --> INF_TF
        INF_TF -->|Secrets| TFI
        INF_TF -->|Secrets| TFP
        TFI --> GCP
        TFI --> OCI
        TFP --> PTN
    end

    subgraph Config [Configuration Management — Ansible]
        ANS[Ansible Playbook]
        INV[Inventory Source<br/>terraform_provider (local)<br/>inventory-ci.yml (CI)]
        USR[system_user role]
        STR[storage role]
        DOCK[docker role]
        TS[Tailscale mesh]
        GFS[glusterfs role<br/>replica-3-arbiter-1 volume]
        SWM[swarm role<br/>3-manager cluster]
        ANS --> INV
        INV --> USR --> STR --> DOCK --> TS --> GFS --> SWM
    end

    subgraph Workloads [Application Workloads — Docker Swarm]
        ISEC[Infisical Agent<br/>.env.tmpl → .env]
        GW[Gateway<br/>Traefik v3 + Socket Proxy]
        AUTH[Auth<br/>Authelia SSO]
        APPS[Service Stacks<br/>Management · Network · Media<br/>Observability · Uptime · Cloud]
        ISEC --> APPS
        GW --> AUTH --> APPS
    end

    IaC -->|Terraform outputs -> inventory handover| Config
    Config -->|Docker + Tailscale + GlusterFS + Swarm| Workloads
```

## Table of Contents

### Core Documentation

- [**Configuration Management (Ansible)**](ansible.md) — Playbooks, roles, dynamic inventory, and the 6-phase provisioning lifecycle
- [**Application Workloads (Stacks)**](stacks.md) — All Docker Swarm stack configurations: Gateway, Auth, Management, Network, Observability, Media/AI, Uptime, Cloud
- [**Utilities (Scripts)**](scripts.md) — Helper scripts and manual execution wrappers

### Infrastructure as Code (Terraform)

- [Infra Root](../terraform/infra/main.tf) — Providers, Infisical integration, OCI/GCP module orchestration
- [Portainer Root](../terraform/portainer-root/main.tf) — Portainer provider configuration and GitOps stack/webhook orchestration
- [GCP Resources](terraform/gcp.md) — VPC, IPv6 subnet, Swarm witness instance
- [OCI Resources](terraform/oci.md) — VCN, DMZ subnet, 2× A1.Flex workers, block volumes, NSGs

### Architecture & Operations

- [**Network Architecture**](network-architecture.md) — Tailscale mesh, 3-manager Swarm topology, GlusterFS replication, overlay networks, DNS & ingress flow
- [**Infisical Secrets Workflow**](infisical-workflow.md) — Agent config, `.env.tmpl` templating, secret injection pipeline
- [**CI Impact Rules**](ci-impact-rules.md) — Centralized path filters and workflow impact-output mapping
- [**Meta-Pipeline Cutover Checklist**](meta-pipeline-cutover-checklist.md) — Minimal first-run checklist (GitHub vars/secrets + Terraform workspace vars)
- [**Deployment Runbook**](deployment-runbook.md) — Stack ordering, deploy commands, verification, rollback procedures
- [**Backup Strategy**](backup-strategy.md) — OCI Silver backup policy, GlusterFS redundancy, application-level backups, recovery

### Guides & External Setups

- [OCI Terraform Cloud OIDC Setup](oci-tfc-oidc-setup.md)
