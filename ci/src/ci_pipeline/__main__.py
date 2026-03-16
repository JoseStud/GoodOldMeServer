"""Dagger CI pipeline entry point.

Reads execution context from environment variables (set by the
compute-context job), constructs the execution DAG, and runs
enabled stages in topological order.

Ansible stages (bootstrap, host-sync, config-sync) run as host
subprocesses — the Tailscale action gives the runner direct SSH
access to swarm nodes without SOCKS5 proxy indirection.

Usage:
    dagger run python -m ci_pipeline

Environment variables (set by orchestrator.yml compute-context job):
    RUN_INFRA_APPLY, RUN_ANSIBLE_BOOTSTRAP, RUN_PORTAINER_APPLY,
    RUN_HOST_SYNC, RUN_CONFIG_SYNC, RUN_HEALTH_REDEPLOY,
    HAS_WORK, STACKS_SHA, ANSIBLE_TAGS, REASON
"""

from __future__ import annotations

import asyncio
import os
import sys

import dagger

from ci_pipeline.phases import ansible, infra, portainer, preflight
from ci_pipeline.proxy import TailscaleProxy


def _bool(var: str) -> bool:
    return os.environ.get(var, "false").lower() == "true"


async def run_pipeline() -> None:
    has_work = _bool("HAS_WORK")
    if not has_work:
        print("pipeline: no work to do (HAS_WORK=false)")
        return

    run_infra_apply = _bool("RUN_INFRA_APPLY")
    run_ansible_bootstrap = _bool("RUN_ANSIBLE_BOOTSTRAP")
    run_portainer_apply = _bool("RUN_PORTAINER_APPLY")
    run_host_sync = _bool("RUN_HOST_SYNC")
    run_config_sync = _bool("RUN_CONFIG_SYNC")
    run_health_redeploy = _bool("RUN_HEALTH_REDEPLOY")
    stacks_sha = os.environ.get("STACKS_SHA", "")
    ansible_tags = os.environ.get("ANSIBLE_TAGS", "")
    reason = os.environ.get("REASON", "")

    needs_inventory = run_ansible_bootstrap or run_host_sync or run_config_sync

    print(f"pipeline: reason={reason} stacks_sha={stacks_sha[:12]}...")

    async with dagger.connect() as client:
        source_dir = client.host().directory(
            ".",
            exclude=[".git", "ci/.venv", "ci/.pytest_cache", "__pycache__"],
        )

        # Set up Tailscale SOCKS5 proxy if available
        proxy: TailscaleProxy | None = None
        try:
            proxy = TailscaleProxy(client)
            print("pipeline: tailscale SOCKS5 proxy bound")
        except Exception:
            print("pipeline: tailscale proxy not available, skipping")

        # ── Layer 1: Parallel preflights ──────────────────────────
        # stacks-sha-trust, secret-validation, and inventory-handover
        # have no dependencies on each other.

        preflight_tasks: list = [
            preflight.stacks_sha_trust(
                client,
                stacks_sha=stacks_sha,
                source_dir=source_dir,
                proxy=proxy,
            ),
            preflight.secret_validation(
                client,
                run_infra=run_infra_apply,
                run_ansible=run_ansible_bootstrap,
                run_portainer=run_portainer_apply,
                run_host_sync=run_host_sync,
                run_health=run_health_redeploy,
                source_dir=source_dir,
                proxy=proxy,
            ),
        ]

        inventory_file: dagger.File | None = None
        if needs_inventory:
            # Run inventory-handover, then preflights concurrently.
            # infra-apply is a separate GHA job that runs before this
            # pipeline, so TFC state is already up to date.
            inventory_file = await infra.inventory_handover(
                client,
                source_dir=source_dir,
                proxy=proxy,
            )

        await asyncio.gather(*preflight_tasks)

        # ── Layer 2: Network policy sync ──────────────────────────
        # Depends on: stacks-sha-trust + secret-validation (both done)

        network_access_policy_json = ""
        policy_json, _ = await preflight.network_policy_sync(
            client,
            source_dir=source_dir,
            proxy=proxy,
        )
        network_access_policy_json = policy_json

        # ── Layer 3: Ansible (host subprocess) ────────────────────
        # Runs directly on the GHA runner via Tailscale, not in Dagger.
        # Depends on: inventory-handover, network-policy-sync

        if run_ansible_bootstrap or run_host_sync:
            if inventory_file:
                await inventory_file.export("inventory-ci.yml")

            tags = ansible_tags
            if run_host_sync and not run_ansible_bootstrap:
                tags = "phase7_runtime_sync"
            ansible.ansible_run(
                inventory_file="inventory-ci.yml",
                stacks_sha=stacks_sha,
                ansible_tags=tags,
            )

        # ── Layer 4: Portainer ────────────────────────────────────
        # post-bootstrap-secret-check, then parallel:
        #   portainer-api-preflight + config-sync (subprocess)
        # then: portainer-apply, then health-gated-redeploy

        if run_portainer_apply:
            await portainer.post_bootstrap_secret_check(
                client,
                source_dir=source_dir,
                proxy=proxy,
            )

        # Parallel: portainer-api-preflight (Dagger) + config-sync (subprocess)
        # Config-sync uses Ansible → runs as subprocess on the host.
        if run_config_sync and inventory_file:
            await inventory_file.export("inventory-ci.yml")
            ansible.ansible_run(
                inventory_file="inventory-ci.yml",
                stacks_sha=stacks_sha,
                ansible_tags="sync-configs",
            )

        if run_portainer_apply or run_health_redeploy:
            await portainer.portainer_api_preflight(
                client,
                source_dir=source_dir,
                network_access_policy_json=network_access_policy_json,
                run_portainer=run_portainer_apply,
                run_health=run_health_redeploy,
                proxy=proxy,
            )

        if run_portainer_apply:
            await portainer.portainer_apply(
                client,
                source_dir=source_dir,
                stacks_sha=stacks_sha,
                proxy=proxy,
            )

        if run_health_redeploy:
            await portainer.health_gated_redeploy(
                client,
                source_dir=source_dir,
                stacks_sha=stacks_sha,
                proxy=proxy,
            )

    print("pipeline: complete")


def main() -> None:
    try:
        asyncio.run(run_pipeline())
    except dagger.ExecError as e:
        print(f"pipeline: stage failed — {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
