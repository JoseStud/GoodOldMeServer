# Configuration Management: Ansible

This section covers the configuration management strategy, detailing every role, the dynamic inventory, SSH authentication, and the full 5-phase provisioning lifecycle.

## Architecture & Integration

Ansible bridges raw Terraform-provisioned infrastructure and the Docker Swarm workloads. It uses a dynamic inventory plugin to auto-discover nodes from Terraform state, then bootstraps them through a deterministic 5-phase sequence: system setup → Docker → Tailscale mesh → GlusterFS storage → Swarm cluster.

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
```

## Dynamic Inventory

The inventory uses the `cloud.terraform.terraform_provider` plugin to pull host information directly from Terraform state — no static IP lists to maintain.

**File:** `ansible/inventory/terraform.yml`

```yaml
plugin: cloud.terraform.terraform_provider
project_path: ../../terraform
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

The `ansible/playbooks/provision.yml` playbook runs all 5 phases sequentially. It starts by waiting for SSH connectivity (up to 300s with 10s delay), gathering facts, and verifying with a ping.

### Phase 1: Base System Setup

**Applies to:** All nodes (system_user), OCI nodes only (storage)

| Role | What It Does | Condition |
|------|-------------|-----------|
| `system_user` | Creates `media-srv` user and group with UID/GID `1500`, no home directory. All containers run file operations as this user for consistent ownership across GlusterFS. | All nodes |
| `storage` | Discovers the unpartitioned block device via `lsblk`, partitions it, formats as ext4, mounts at `/mnt/app_data`, sets ownership to `{{ service_user }}:{{ service_group }}` with mode `0755`. | OCI nodes only (`oci_nodes` group) |

### Phase 2: Docker Engine

**Applies to:** All nodes

| Role | What It Does |
|------|-------------|
| `docker` | Adds Docker's official APT repository (GPG key + apt source), installs `docker-ce`, `docker-ce-cli`, `containerd.io`, and `docker-compose-plugin`, enables the `docker` systemd service, adds `{{ service_user }}` to the `docker` group |

### Phase 3: Tailscale Mesh Networking

**Applies to:** All nodes (inline tasks, no role)

1. **Install Tailscale** — Adds the official Tailscale APT repository (GPG key + apt source), installs the `tailscale` package
2. **Authenticate** — Checks `tailscale status --json` for existing connection; only runs `tailscale up --authkey=$TAILSCALE_OAUTH_CLIENT_SECRET --ssh` if not already authenticated
3. **Verify** — Asserts exit code 0; fails with descriptive message if auth key is invalid

After this phase, all 3 nodes (2 OCI + 1 GCP) can communicate over Tailscale's encrypted mesh using private IPs, regardless of cloud provider or network topology.

> **Important:** The `TAILSCALE_OAUTH_CLIENT_SECRET` must be set as an environment variable before running the playbook. Generate an OAuth client with appropriate read/write tags from the Tailscale admin console.

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
├── auth/authelia/config/
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

## Structure

```
ansible/
├── ansible.cfg                      # SSH cert auth, inventory path, remote_user=ubuntu
├── requirements.yml                 # Galaxy collection dependencies
├── inventory/
│   └── terraform.yml                # Dynamic inventory from Terraform state
├── playbooks/
│   └── provision.yml                # 5-phase provisioning playbook (with tags)
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
    │   ├── defaults/main.yml        # Parameterized volume name, paths
    │   └── tasks/main.yml           # GlusterFS replica-3-arbiter-1 volume + shared dirs
    └── swarm/tasks/main.yml         # 3-manager Swarm init + overlay network
```

## Running Ansible

```bash
# Set the Tailscale OAuth credentials (required for Phase 3)
export TAILSCALE_OAUTH_CLIENT_ID="..."
export TAILSCALE_OAUTH_CLIENT_SECRET="tskey-client-..."

# Run the full provisioning playbook
ansible-playbook -i inventory/terraform.yml playbooks/provision.yml

# Run against specific groups
ansible-playbook -i inventory/terraform.yml playbooks/provision.yml --limit oci_nodes
ansible-playbook -i inventory/terraform.yml playbooks/provision.yml --limit gcp_witness
```

> **Prerequisites:** Terraform must have been applied first (the dynamic inventory reads from Terraform state). Ensure `~/.ssh/id_rsa-cert.pub` is a valid signed certificate.
