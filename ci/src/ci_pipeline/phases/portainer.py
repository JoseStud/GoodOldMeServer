"""Portainer stages: post-bootstrap-secret-check, portainer-api-preflight,
portainer-apply, config-sync, health-gated-redeploy.
"""

from __future__ import annotations

import os

import dagger

from ci_pipeline.containers import container_from_profile
from ci_pipeline.proxy import TailscaleProxy


# ---------------------------------------------------------------------------
# Helper: wire common Infisical env vars into a container
# ---------------------------------------------------------------------------


def _wire_infisical(
    ctr: dagger.Container, client: dagger.Client
) -> dagger.Container:
    for var in (
        "INFISICAL_PROJECT_ID",
        "INFISICAL_MACHINE_IDENTITY_ID",
        "INFISICAL_OIDC_AUDIENCE",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_env_variable(var, val)

    for var in (
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        "ACTIONS_ID_TOKEN_REQUEST_URL",
        "INFISICAL_TOKEN",
        "INFISICAL_AGENT_CLIENT_ID",
        "INFISICAL_AGENT_CLIENT_SECRET",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_secret_variable(var, client.set_secret(var, val))

    return ctr


# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------


async def post_bootstrap_secret_check(
    client: dagger.Client,
    *,
    source_dir: dagger.Directory,
    proxy: TailscaleProxy | None = None,
) -> None:
    """Validate bootstrap-managed Portainer secrets."""
    ctr = container_from_profile(client, "infisical")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
    )
    ctr = _wire_infisical(ctr, client)

    if proxy:
        ctr = proxy.bind(ctr)

    output = await (
        ctr
        .with_exec(["bash", ".github/scripts/stages/post_bootstrap_secret_check.sh"])
        .stdout()
    )
    print(f"post-bootstrap-secret-check: {output.strip()}")


async def portainer_api_preflight(
    client: dagger.Client,
    *,
    source_dir: dagger.Directory,
    network_access_policy_json: str = "",
    run_portainer: bool = False,
    run_health: bool = False,
    proxy: TailscaleProxy | None = None,
) -> None:
    """Preflight Portainer API reachability and allowlist propagation."""
    ctr = container_from_profile(client, "infisical")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
        .with_env_variable("RUN_PORTAINER", str(run_portainer).lower())
        .with_env_variable("RUN_HEALTH", str(run_health).lower())
    )

    if network_access_policy_json:
        ctr = ctr.with_env_variable(
            "NETWORK_ACCESS_POLICY_JSON", network_access_policy_json
        )

    ctr = _wire_infisical(ctr, client)

    if proxy:
        ctr = proxy.bind(ctr)

    output = await (
        ctr
        .with_exec(["bash", ".github/scripts/stages/portainer_api_preflight.sh"])
        .stdout()
    )
    print(f"portainer-api-preflight: {output.strip()}")


async def portainer_apply(
    client: dagger.Client,
    *,
    source_dir: dagger.Directory,
    stacks_sha: str = "",
    proxy: TailscaleProxy | None = None,
) -> None:
    """Terraform plan/apply for portainer-root workspace."""
    ctr = container_from_profile(client, "terraform")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
        .with_env_variable(
            "SHADOW_MODE", os.environ.get("SHADOW_MODE", "false")
        )
    )

    if stacks_sha:
        ctr = ctr.with_env_variable("STACKS_SHA", stacks_sha)
        ctr = ctr.with_env_variable("TF_VAR_stacks_sha", stacks_sha)

    for var in (
        "TFC_ORGANIZATION",
        "TFC_WORKSPACE_PORTAINER",
        "INFISICAL_PROJECT_ID",
    ):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_env_variable(var, val)

    # TF_VAR passthrough
    tf_var_infisical_project_id = os.environ.get("INFISICAL_PROJECT_ID", "")
    if tf_var_infisical_project_id:
        ctr = ctr.with_env_variable(
            "TF_VAR_infisical_project_id", tf_var_infisical_project_id
        )

    for var in ("TFC_TOKEN", "INFISICAL_TOKEN"):
        val = os.environ.get(var, "")
        if val:
            secret = client.set_secret(var, val)
            ctr = ctr.with_secret_variable(var, secret)
            if var == "TFC_TOKEN":
                ctr = ctr.with_secret_variable("TF_TOKEN_app_terraform_io", secret)

    ctr = _wire_infisical(ctr, client)

    if proxy:
        ctr = proxy.bind(ctr)

    output = await (
        ctr
        .with_exec(["bash", ".github/scripts/stages/portainer_apply.sh"])
        .stdout()
    )
    print(f"portainer-apply: {output.strip()}")


async def health_gated_redeploy(
    client: dagger.Client,
    *,
    source_dir: dagger.Directory,
    stacks_sha: str = "",
    proxy: TailscaleProxy | None = None,
) -> None:
    """Trigger health-gated webhook redeployments."""
    ctr = container_from_profile(client, "webhook")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
        .with_env_variable("FULL_STACKS_RECONCILE", "true")
        .with_env_variable(
            "REDEPLOY_TIMEOUT_SECONDS",
            os.environ.get("REDEPLOY_TIMEOUT_SECONDS", "2400"),
        )
        .with_env_variable(
            "SHADOW_MODE", os.environ.get("SHADOW_MODE", "false")
        )
    )

    if stacks_sha:
        ctr = ctr.with_env_variable("STACKS_SHA", stacks_sha)

    ctr = _wire_infisical(ctr, client)

    if proxy:
        ctr = proxy.bind(ctr)

    output = await (
        ctr
        .with_exec(["bash", ".github/scripts/stages/health_gated_redeploy.sh"])
        .stdout()
    )
    print(f"health-gated-redeploy: {output.strip()}")
