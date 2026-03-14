"""Infra stages: inventory-handover.

infra-apply stays as a standalone GHA job using marketplace actions.
"""

from __future__ import annotations

import os

import dagger

from ci_pipeline.containers import container_from_profile
from ci_pipeline.proxy import TailscaleProxy


async def inventory_handover(
    client: dagger.Client,
    *,
    source_dir: dagger.Directory,
    tfc_workspace: str = "",
    output_file: str = "inventory-ci.yml",
    proxy: TailscaleProxy | None = None,
) -> dagger.File:
    """Render Ansible inventory from TFC outputs.

    Runs .github/scripts/tfc/render_inventory_from_tfc_outputs.sh
    inside a base container.  Returns the rendered inventory as a
    Dagger File for downstream stages.
    """
    workspace = tfc_workspace or os.environ.get(
        "TFC_WORKSPACE_INFRA", "goodoldme-infra"
    )

    ctr = container_from_profile(client, "base")
    ctr = (
        ctr
        .with_mounted_directory("/work", source_dir)
        .with_workdir("/work")
    )

    # TFC credentials
    for var in ("TFC_ORGANIZATION",):
        val = os.environ.get(var, "")
        if val:
            ctr = ctr.with_env_variable(var, val)

    tfc_token = os.environ.get("TFC_TOKEN", "")
    if tfc_token:
        ctr = ctr.with_secret_variable(
            "TFC_TOKEN", client.set_secret("tfc-token", tfc_token)
        )

    if proxy:
        ctr = proxy.bind(ctr)

    ctr = ctr.with_exec([
        "bash",
        ".github/scripts/tfc/render_inventory_from_tfc_outputs.sh",
        workspace,
        output_file,
    ])

    inventory_file = ctr.file(f"/work/{output_file}")
    print(f"inventory-handover: rendered {output_file}")
    return inventory_file
