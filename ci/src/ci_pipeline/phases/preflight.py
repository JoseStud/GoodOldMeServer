"""Preflight stages: stacks-sha-trust, secret-validation, network-policy-sync.

Each function takes a Dagger client, the execution context, and optional
proxy/secrets, and runs the corresponding bash script inside a container.
"""

from __future__ import annotations

import os

import dagger

from ci_pipeline.containers import container_from_profile
from ci_pipeline.proxy import TailscaleProxy


async def stacks_sha_trust(
    client: dagger.Client,
    *,
    stacks_sha: str,
    source_dir: dagger.Directory,
    proxy: TailscaleProxy | None = None,
) -> None:
    """Verify stacks SHA is on main lineage with green CI signals.

    Runs .github/scripts/stacks/verify_trusted_stacks_sha.sh inside
    a base container with curl and jq.
    """
    if not stacks_sha:
        print("stacks-sha-trust: skipped (no stacks_sha)")
        return

    github_token = os.environ.get("GITHUB_TOKEN", "")
    stacks_repo_read_token = os.environ.get("STACKS_REPO_READ_TOKEN", "")

    ctr = container_from_profile(client, "base")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
        .with_env_variable("WAIT_FOR_SUCCESS", "true")
        .with_env_variable(
            "WAIT_TIMEOUT_SECONDS",
            os.environ.get("WAIT_TIMEOUT_SECONDS", "900"),
        )
        .with_env_variable(
            "POLL_INTERVAL_SECONDS",
            os.environ.get("POLL_INTERVAL_SECONDS", "15"),
        )
    )

    if github_token:
        ctr = ctr.with_secret_variable(
            "GITHUB_TOKEN", client.set_secret("github-token", github_token)
        )
    if stacks_repo_read_token:
        ctr = ctr.with_secret_variable(
            "STACKS_REPO_READ_TOKEN",
            client.set_secret("stacks-repo-read-token", stacks_repo_read_token),
        )

    if proxy:
        ctr = proxy.bind(ctr)

    output = await (
        ctr
        .with_exec([
            "bash", ".github/scripts/stacks/verify_trusted_stacks_sha.sh",
            stacks_sha,
        ])
        .stdout()
    )
    print(f"stacks-sha-trust: {output.strip()}")


async def secret_validation(
    client: dagger.Client,
    *,
    run_infra: bool,
    run_ansible: bool,
    run_portainer: bool,
    run_host_sync: bool,
    run_health: bool,
    source_dir: dagger.Directory,
    proxy: TailscaleProxy | None = None,
) -> None:
    """Validate required Infisical secrets for enabled stages.

    Runs .github/scripts/stages/secret_validation.sh inside an
    infisical container.
    """
    if not any([run_infra, run_ansible, run_portainer, run_host_sync, run_health]):
        print("secret-validation: skipped (no stages enabled)")
        return

    ctr = container_from_profile(client, "infisical")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
        .with_env_variable("RUN_INFRA", str(run_infra).lower())
        .with_env_variable("RUN_ANSIBLE", str(run_ansible).lower())
        .with_env_variable("RUN_PORTAINER", str(run_portainer).lower())
        .with_env_variable("RUN_HOST_SYNC", str(run_host_sync).lower())
        .with_env_variable("RUN_HEALTH", str(run_health).lower())
    )

    # Infisical credentials
    for var in (
        "INFISICAL_PROJECT_ID",
        "INFISICAL_MACHINE_IDENTITY_ID",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_env_variable(var, val)

    for var in (
        "INFISICAL_TOKEN",
        "INFISICAL_AGENT_CLIENT_ID",
        "INFISICAL_AGENT_CLIENT_SECRET",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_secret_variable(var, client.set_secret(var, val))

    # OIDC token passthrough for Infisical
    for var in (
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        "ACTIONS_ID_TOKEN_REQUEST_URL",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_secret_variable(var, client.set_secret(var, val))

    if proxy:
        ctr = proxy.bind(ctr)

    output = await (
        ctr
        .with_exec(["bash", ".github/scripts/stages/secret_validation.sh"])
        .stdout()
    )
    print(f"secret-validation: {output.strip()}")


async def network_policy_sync(
    client: dagger.Client,
    *,
    source_dir: dagger.Directory,
    proxy: TailscaleProxy | None = None,
) -> tuple[str, str]:
    """Build and sync network access policy.

    Runs .github/scripts/stages/network_policy_sync.sh inside a
    network container.  Returns (policy_json, allowed_cidrs).
    """
    ctr = container_from_profile(client, "network")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
        .with_env_variable(
            "SHADOW_MODE", os.environ.get("SHADOW_MODE", "false")
        )
    )

    # TFC + Infisical credentials
    for var in (
        "TFC_ORGANIZATION",
        "TFC_WORKSPACE_INFRA",
        "INFISICAL_PROJECT_ID",
        "INFISICAL_MACHINE_IDENTITY_ID",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_env_variable(var, val)

    for var in (
        "TFC_TOKEN",
        "INFISICAL_TOKEN",
        "INFISICAL_AGENT_CLIENT_ID",
        "INFISICAL_AGENT_CLIENT_SECRET",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_secret_variable(var, client.set_secret(var, val))

    # OIDC token passthrough
    for var in (
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        "ACTIONS_ID_TOKEN_REQUEST_URL",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_secret_variable(var, client.set_secret(var, val))

    if proxy:
        ctr = proxy.bind(ctr)

    # Write outputs to a file so we can read them back
    github_output = "/tmp/github_output"
    ctr = ctr.with_env_variable("GITHUB_OUTPUT", github_output)
    ctr = ctr.with_exec([
        "bash", "-c",
        f"touch {github_output} && bash .github/scripts/stages/network_policy_sync.sh",
    ])

    output_content = await ctr.file(github_output).contents()

    policy_json = ""
    allowed_cidrs = ""
    for line in output_content.strip().splitlines():
        if line.startswith("network_access_policy_json="):
            policy_json = line.split("=", 1)[1]
        elif line.startswith("portainer_automation_allowed_cidrs="):
            allowed_cidrs = line.split("=", 1)[1]

    print(f"network-policy-sync: policy={len(policy_json)} bytes")
    return policy_json, allowed_cidrs
