# Configuration Management: Ansible

This section covers the configuration management strategy, detailing every role, the inventory sources, SSH authentication, and the full 6-phase provisioning lifecycle.

## Architecture & Integration

Ansible bridges raw Terraform-provisioned infrastructure and the Docker Swarm workloads. Local runs use a dynamic inventory plugin to auto-discover nodes from Terraform state, while CI renders a deterministic `inventory-ci.yml` artifact from Terraform Cloud outputs (`oci_public_ips`, `gcp_witness_ipv6`) before executing Ansible.

```mermaid
sequenceDiagram
    participant TF as Terraform State
    participant INV as Dynamic Inventory<br/>(terraform_provider plugin)
    participant PB as provision.yml
    participant OCI1 as OCI Worker 1
    participant OCI2 as OCI Worker 2
    participant GCP as GCP Witness

    TF->>INV: Emits IPs & provider metadata
    INV->>PB: Groups: oci_nodes (OCI), gcp_witness (GCP)

    Note over PB,GCP: Phase 1 — Base Setup
    PB->>OCI1: system_user role (media-srv UID 1500)
    PB->>OCI2: system_user role
    PB->>GCP: system_user role
    PB->>OCI1: storage role (partition /dev/sdb → /mnt/app_data)
    PB->>OCI2: storage role

    Note over PB,GCP: Phase 2 — Docker Engine
    PB->>OCI1: docker role (install + enable)
    PB->>OCI2: docker role
    PB->>GCP: docker role

    Note over PB,GCP: Phase 3 — Tailscale Mesh
    PB->>OCI1: Install + auth Tailscale
    PB->>OCI2: Install + auth Tailscale
    PB->>GCP: Install + auth Tailscale

    Note over PB,GCP: Phase 4 — GlusterFS
    PB->>OCI1: glusterfs role (replica-3-arbiter-1 volume)
    PB->>OCI2: glusterfs role (peer + mount)
    PB->>GCP: glusterfs role (arbiter brick)

    Note over PB,GCP: Phase 5 — Swarm Bootstrap
    PB->>OCI1: swarm role (init manager)
    PB->>OCI2: swarm role (join as manager)
    PB->>GCP: swarm role (join as witness manager)
    PB->>OCI1: Label nodes + create traefik_proxy network

    Note over PB,GCP: Phase 6 — Portainer Bootstrap
    PB->>OCI1: portainer_bootstrap role (deploy management stack)
    PB->>OCI1: Wait for Portainer API health
    PB->>OCI1: Init admin user + create API key
    PB->>OCI1: Write PORTAINER_URL + PORTAINER_API_URL + API_KEY to Infisical /management
```

## Dynamic Inventory

The local inventory uses the `cloud.terraform.terraform_provider` plugin to pull host information directly from Terraform state — no static IP lists to maintain.

**File:** `ansible/inventory/terraform.yml`

```yaml
plugin: cloud.terraform.terraform_provider
project_path: ../../terraform/infra
```

| Group | Provider Match | Hosts | `ansible_user` |
|-------|---------------|-------|----------------|
| `oci_nodes` | `'oci' in provider` | 2× OCI A1.Flex workers | `ubuntu` |
| `gcp_witness` | `'google' in provider` | 1× GCP e2-micro witness | `debian` |

**Host resolution:** OCI nodes use `public_ip` (IPv4); the GCP witness falls back to `witness_ipv6` when `public_ip` is unavailable.

## SSH Certificate Authentication

Ansible connects using SSH certificate-based auth instead of password or key-pair authentication. This is configured in `ansible/ansible.cfg`:

```ini
[ssh_connection]
ssh_args = -o CertificateFile=~/.ssh/id_rsa-cert.pub -o IdentityFile=~/.ssh/id_rsa
```

**How it works:**
1. Terraform's OCI module injects the SSH CA public key into each instance via cloud-init (`TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem`)
2. The operator signs their SSH public key with the CA private key to generate `~/.ssh/id_rsa-cert.pub`
3. Ansible presents the certificate on connection — the remote sshd validates it against the trusted CA

This eliminates the need to distribute individual public keys to each node.

## Provisioning Lifecycle

The `ansible/playbooks/provision.yml` playbook runs all 6 phases sequentially. It starts by waiting for SSH connectivity (up to 300s with 10s delay), gathering facts, and verifying with a ping.

### Phase 1: Base System Setup

**Applies to:** All nodes (system_user), OCI nodes only (storage)

| Role | What It Does | Condition |
|------|-------------|-----------|
| `system_user` | Creates `media-srv` user and group with UID/GID `1500`, no home directory. All containers run file operations as this user for consistent ownership across GlusterFS. | All nodes |
| `storage` | Partitions `{{ block_device }}`, formats `{{ block_device_partition }}` as ext4, mounts at `{{ mount_point }}`, and sets ownership to `{{ service_user }}:{{ service_group }}` with mode `0755`. Defaults are `/dev/sdb`, `/dev/sdb1` (or `p1` for NVMe), `/mnt/app_data`. | OCI nodes only (`oci_nodes` group) |

### Phase 2: Docker Engine

**Applies to:** All nodes

| Role | What It Does |
|------|-------------|
| `docker` | Adds Docker's official APT repository (GPG key + apt source), installs `docker-ce`, `docker-ce-cli`, `containerd.io`, and `docker-compose-plugin`, enables the `docker` systemd service, adds `{{ service_user }}` to the `docker` group |

### Phase 3: Tailscale Mesh Networking

**Applies to:** All nodes (inline tasks, no role)

1. **Install Tailscale** — Adds the official Tailscale APT repository (GPG key + apt source), installs the `tailscale` package
2. **Authenticate** — Checks `tailscale status --json` for existing connection; only runs `tailscale up --authkey=$TAILSCALE_OAUTH_CLIENT_ID --ssh` if not already authenticated
3. **Verify** — Asserts exit code 0; fails with descriptive message if auth key is invalid

After this phase, all 3 nodes (2 OCI + 1 GCP) can communicate over Tailscale's encrypted mesh using private IPs, regardless of cloud provider or network topology.

> **Important:** The `TAILSCALE_OAUTH_CLIENT_ID` must be set as an environment variable before running the playbook. Generate an OAuth client with appropriate read/write tags from the Tailscale admin console.

### Phase 4: GlusterFS Distributed Storage

**Applies to:** OCI nodes only

| Role | What It Does |
|------|-------------|
| `glusterfs` | Installs GlusterFS server and client, creates a **replica 3 arbiter 1** volume `swarm_data` across both OCI nodes (full bricks) and GCP witness (arbiter brick) over Tailscale IPv4, mounts at `/mnt/swarm-shared`, and pre-creates the entire shared directory tree |

**Detailed flow:**
1. Install `glusterfs-server`, start `glusterd` service
2. Gather Tailscale IPv4 address (`tailscale ip -4`) on each OCI node
3. Create brick directory at `/mnt/app_data/gluster_brick`
4. **Peer probing** — Each node probes the other (bidirectional, idempotent)
5. **Volume creation** — From the first OCI node, creates `swarm_data` as `replica 3 arbiter 1 transport tcp` using both OCI nodes' Tailscale IPs as full brick endpoints and the GCP witness Tailscale IP as the arbiter brick
6. **Start volume** and mount via `localhost:/swarm_data` with `glusterfs` fstype and `_netdev` option
7. **Pre-create shared directories** (from first OCI node) for all stacks:

```
/mnt/swarm-shared/
├── auth/{authelia/config,authelia-db}/
├── ai-interface/open-webui/
├── ai-interface/openclaw/config/
├── observability/{prometheus_data,loki_data,grafana_data,prometheus,loki,promtail}/
├── gateway/traefik_acme/
├── management/{homarr/appdata,portainer/data}/
├── network/{vaultwarden/data,vaultwarden-db,pihole/node{1,2}/{etc-pihole,etc-dnsmasq.d}}/
├── uptime-kuma/data/
└── cloud/filebrowser/database/
```

All directories are owned by `media-srv:media-srv` (UID/GID 1500) with mode `0755`.

> See [Network Architecture](network-architecture.md#glusterfs-replication) for replication strategy and split-brain considerations.

### Phase 5: Swarm Bootstrap

**Applies to:** All nodes

| Role | What It Does |
|------|-------------|
| `swarm` | Initializes a 3-manager Docker Swarm cluster over the Tailscale mesh, labels nodes, and creates the `traefik_proxy` overlay network |

**Detailed flow:**
1. Gather Tailscale IPv4 on every node
2. Check if already in a Swarm (`docker info --format '{{.Swarm.LocalNodeState}}'`)
3. **First OCI node** — `docker swarm init --advertise-addr <ts_ip> --listen-addr <ts_ip>:2377`
4. Retrieve manager join token
5. **Second OCI node** — `docker swarm join --token <token> --advertise-addr <ts_ip> <first_ts_ip>:2377`
6. **GCP witness** — Same join command (joins as a 3rd manager for Raft quorum)
7. **Label nodes:**
   - OCI nodes: `location=cloud`
   - GCP witness: `role=witness`
8. **Create overlay network:** `traefik_proxy` (attachable, overlay driver) — used by all stacks

> See [Network Architecture](network-architecture.md#docker-swarm-topology) for the 3-manager quorum rationale.

### Phase 6: Portainer Bootstrap

**Applies to:** First OCI manager node only

| Role | What It Does |
|------|-------------|
| `portainer_bootstrap` | Deploys the management stack (Portainer server + agent + Homarr) via `docker stack deploy`, waits for the Portainer API to be healthy, generates a bcrypt hash of the admin password, writes `PORTAINER_ADMIN_PASSWORD_HASH` to Infisical `/stacks/management`, repairs/rotates the Terraform API key if needed, and writes `PORTAINER_URL` + `PORTAINER_API_URL` + `PORTAINER_API_KEY` to Infisical `/management` |

**Detailed flow:**
1. Generate a bcrypt hash of `PORTAINER_ADMIN_PASSWORD` (Ansible `password_hash('bcrypt')` filter)
2. Deploy the management stack using `docker stack deploy -c /opt/stacks/management/docker-compose.yml management`, passing `PORTAINER_ADMIN_PASSWORD_HASH` as an environment variable
3. Wait for `http://localhost:9000/api/system/status` to return HTTP 200 (up to 120s)
4. Admin user is initialized automatically by Portainer via the `--admin-password` CLI flag (bcrypt hash) — no API call needed. This is idempotent and avoids transmitting the plaintext password over HTTP
5. Authenticate via `POST /api/auth` to get a JWT
6. Validate any existing `PORTAINER_API_KEY` from environment (`GET /api/system/status`); if missing/invalid, rotate `terraform-managed` token(s) and mint a new raw key
7. Write `PORTAINER_ADMIN_PASSWORD_HASH` to Infisical `/stacks/management`
8. Write `PORTAINER_URL`, `PORTAINER_API_URL`, and `PORTAINER_API_KEY` to Infisical `/management` via the Infisical CLI
9. Verify the API key works against the Portainer status endpoint

**Why Ansible and not Terraform?** Portainer is the control plane that Terraform's Portainer provider talks to. Terraform cannot create the thing it depends on to authenticate. Ansible bootstraps Portainer as infrastructure, then Terraform manages the application stacks through it.

> **Required environment variables:**
> - `PORTAINER_ADMIN_PASSWORD` — initial admin password (hashed to bcrypt at deploy time; plaintext is used only for JWT auth to create the API key)
> - `BASE_DOMAIN` — your domain (e.g., `example.com`)
> - `INFISICAL_TOKEN` — Infisical auth token (for writing secrets)
> - `INFISICAL_PROJECT_ID` — Infisical project ID
> - `HOMARR_SECRET_KEY` — Homarr encryption key

## Structure

```
ansible/
├── ansible.cfg                      # SSH cert auth, inventory path, remote_user=ubuntu
├── requirements.yml                 # Galaxy collection dependencies
├── inventory/
│   └── terraform.yml                # Dynamic inventory from Terraform state
├── playbooks/
│   └── provision.yml                # 6-phase provisioning playbook (with tags)
└── roles/
    ├── system_user/
    │   ├── defaults/main.yml        # Parameterized user/group (service_user, service_uid)
    │   └── tasks/main.yml           # Create service user/group
    ├── storage/
    │   ├── defaults/main.yml        # Parameterized device/mount point
    │   └── tasks/main.yml           # Discover block device, partition + mount
    ├── docker/
    │   ├── defaults/main.yml        # Parameterized user
    │   └── tasks/main.yml           # APT repo install Docker, enable service
    ├── glusterfs/
    │   ├── defaults/main.yml        # (currently empty — values are inline in tasks)
    │   ├── templates/               # (reserved for future Jinja2 templates)
    │   └── tasks/main.yml           # GlusterFS replica-3-arbiter-1 volume + shared dirs
    ├── swarm/
    │   └── tasks/main.yml           # 3-manager Swarm init + overlay network
    └── portainer_bootstrap/
        ├── defaults/main.yml        # Portainer URL, admin creds, Infisical project ID
        └── tasks/main.yml           # Deploy management stack, init admin, create API key
```

## Running Ansible

```bash
# Set the Tailscale OAuth credentials (required for Phase 3)
export TAILSCALE_OAUTH_CLIENT_ID="..."

# Run the full provisioning playbook
ansible-playbook -i inventory/terraform.yml playbooks/provision.yml

# Run against specific groups
ansible-playbook -i inventory/terraform.yml playbooks/provision.yml --limit oci_nodes
ansible-playbook -i inventory/terraform.yml playbooks/provision.yml --limit gcp_witness
```

> **Prerequisites:** Terraform infra must be applied first. Local runs read from Terraform state (`inventory/terraform.yml`), while CI uses the rendered `inventory-ci.yml` artifact. Ensure your SSH certificate is valid.
