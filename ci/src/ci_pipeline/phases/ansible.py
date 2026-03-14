"""Ansible stages: ansible-bootstrap, host-sync, config-sync.

These stages run as host subprocesses, not inside Dagger containers.
The Tailscale action gives the GHA runner direct network access to
swarm nodes — SSH works natively without SOCKS5 proxy indirection.
Ansible and its dependencies are installed on the runner via
setup-python + pip in the workflow.
"""

from __future__ import annotations

import os
import subprocess
import sys


def ansible_run(
    *,
    inventory_file: str = "inventory-ci.yml",
    stacks_sha: str = "",
    ansible_tags: str = "",
) -> None:
    """Run ansible-playbook on the host via subprocess.

    Calls .github/scripts/stages/ansible_run.sh which handles:
    - Infisical OIDC login
    - Ephemeral SSH certificate generation
    - Stacks SHA checkout (if provided)
    - ansible-playbook with optional --tags
    """
    env = os.environ.copy()
    env["INVENTORY_FILE"] = inventory_file
    if stacks_sha:
        env["STACKS_SHA"] = stacks_sha
    if ansible_tags:
        env["ANSIBLE_TAGS"] = ansible_tags

    result = subprocess.run(
        ["bash", ".github/scripts/stages/ansible_run.sh"],
        env=env,
        check=False,
    )
    if result.returncode != 0:
        print("ansible-run: FAILED", file=sys.stderr)
        sys.exit(result.returncode)
    print("ansible-run: done")
