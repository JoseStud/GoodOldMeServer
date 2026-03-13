"""GitHub Actions I/O: env var reading and output emission."""

from __future__ import annotations

import os
import random

from .models import ResolveContext


def read_env_context() -> ResolveContext:
    """Build a ResolveContext from GitHub Actions environment variables.

    Variable names match reusable-resolve-plan.yml lines 69-83.
    """

    def _to_bool(value: str) -> bool:
        return value.lower() in ("true", "1", "yes")

    return ResolveContext(
        event_name=os.environ.get("EVENT_NAME", ""),
        ci_plan_mode=os.environ.get("CI_PLAN_MODE", "meta"),
        push_before=os.environ.get("PUSH_BEFORE", ""),
        push_sha=os.environ.get("PUSH_SHA", ""),
        payload_json=os.environ.get("PAYLOAD_JSON", ""),
        payload_stacks_sha=os.environ.get("PAYLOAD_STACKS_SHA", ""),
        payload_reason=os.environ.get("PAYLOAD_REASON", ""),
        payload_source_repo=os.environ.get("PAYLOAD_SOURCE_REPO", ""),
        payload_source_run_id=os.environ.get("PAYLOAD_SOURCE_RUN_ID", ""),
        payload_source_sha=os.environ.get("PAYLOAD_SOURCE_SHA", ""),
        validate_dispatch_contract=_to_bool(
            os.environ.get("VALIDATE_DISPATCH_CONTRACT", "true")
        ),
    )


def emit_output(key: str, value: str) -> None:
    """Write a key=value pair to $GITHUB_OUTPUT.

    Handles multiline values using the heredoc delimiter form required by
    GitHub Actions.
    """
    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if not output_path:
        return

    with open(output_path, "a") as f:
        if "\n" in value:
            delimiter = f"EOF_{random.randint(0, 99999)}_{random.randint(0, 99999)}"
            f.write(f"{key}<<{delimiter}\n{value}\n{delimiter}\n")
        else:
            f.write(f"{key}={value}\n")
