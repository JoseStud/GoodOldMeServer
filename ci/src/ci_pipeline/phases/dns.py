"""DNS stages: cloudflare-dns-sync."""

from __future__ import annotations

import os

import dagger

from ci_pipeline.containers import container_from_profile
from ci_pipeline.proxy import TailscaleProxy


async def cloudflare_dns_sync(
    client: dagger.Client,
    *,
    source_dir: dagger.Directory,
    proxy: TailscaleProxy | None = None,
) -> None:
    """Reconcile Cloudflare round-robin DNS A records for all portainer-managed stacks.

    Fetches OCI public IPs from TFC outputs and runs
    .github/scripts/stages/cloudflare_dns_sync.sh inside a network container
    (curl, jq, yq, infisical CLI).

    NOTE: proxy is intentionally unused — Cloudflare's public API must not be
    routed through the Tailscale SOCKS5 proxy.
    """
    _ = proxy  # Cloudflare API is public internet; never route via Tailscale proxy

    ctr = container_from_profile(client, "network")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
    )

    # Infisical credentials
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

    # TFC credentials for fetching OCI public IPs
    for var in ("TFC_ORGANIZATION", "TFC_WORKSPACE_INFRA"):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_env_variable(var, val)

    tfc_token = os.environ.get("TFC_TOKEN", "")
    if tfc_token:
        ctr = ctr.with_secret_variable(
            "TFC_TOKEN", client.set_secret("tfc-token-dns", tfc_token)
        )

    output = await (
        ctr
        .with_exec(["bash", ".github/scripts/stages/cloudflare_dns_sync.sh"])
        .stdout()
    )
    print(f"cloudflare-dns-sync: {output.strip()}")
