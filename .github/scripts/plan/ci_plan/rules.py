"""Declarative mappings for plan resolution."""

ROLE_PHASE_MAP: dict[str, str] = {
    "ansible/roles/system_user/": "phase1_base",
    "ansible/roles/storage/": "phase1_base",
    "ansible/roles/docker/": "phase2_docker",
    "ansible/roles/tailscale/": "phase3_tailscale",
    "ansible/roles/glusterfs/": "phase4_glusterfs",
    "ansible/roles/swarm/": "phase5_swarm",
    "ansible/roles/portainer_bootstrap/": "phase6_portainer",
    "ansible/roles/runtime_sync/": "phase7_runtime_sync",
}

ANSIBLE_ONLY_PREFIXES = ("ansible/",)
ANSIBLE_ONLY_EXACT = (".ansible-lint",)
