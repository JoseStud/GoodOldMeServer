"""Compute orchestrator execution context from event data.

Replaces the inline bash + embedded Python in orchestrator.yml's
compute-context job.  Produces identical outputs to $GITHUB_OUTPUT.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Protocol


# ---------------------------------------------------------------------------
# Role-to-phase mapping (ported from deleted rules.py)
# ---------------------------------------------------------------------------

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
# NOTE: metadata-only classification is evaluated before ansible-only.
# .ansible-lint remains here so mixed changes like:
#   .ansible-lint + ansible/roles/*
# still classify as ansible-only (infra skipped) rather than full-run.

METADATA_ONLY_PREFIXES = (
    "docs/",
    ".github/",
    "ci/",
)
METADATA_ONLY_EXACT = (
    ".ansible-lint",
)

STACKS_SHA_ONLY_EXACT = (
    "stacks",
    ".gitmodules",
)

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_NULL_SHA = "0" * 40


# ---------------------------------------------------------------------------
# Git interface (protocol for testability)
# ---------------------------------------------------------------------------


class GitInterface(Protocol):
    def diff_name_only(self, before: str, after: str) -> list[str]: ...
    def rev_parse(self, ref: str) -> str: ...


class RealGit:
    def diff_name_only(self, before: str, after: str) -> list[str]:
        result = subprocess.run(
            ["git", "diff", "--name-only", before, after],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return []
        return [f for f in result.stdout.strip().splitlines() if f]

    def rev_parse(self, ref: str) -> str:
        result = subprocess.run(
            ["git", "rev-parse", ref],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return ""
        return result.stdout.strip()


# ---------------------------------------------------------------------------
# Execution context
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ExecutionContext:
    run_infra_apply: bool = False
    run_ansible_bootstrap: bool = False
    run_portainer_apply: bool = False
    run_host_sync: bool = False
    run_config_sync: bool = False
    run_health_redeploy: bool = False
    ansible_tags: str = ""
    stacks_sha: str = ""
    reason: str = ""

    @property
    def has_work(self) -> bool:
        return (
            self.run_infra_apply
            or self.run_ansible_bootstrap
            or self.run_portainer_apply
            or self.run_host_sync
            or self.run_config_sync
            or self.run_health_redeploy
        )


# ---------------------------------------------------------------------------
# Ansible tag computation
# ---------------------------------------------------------------------------


def is_ansible_only(changed_files: list[str]) -> bool:
    """True if every changed file is under ansible/ or is .ansible-lint."""
    if not changed_files:
        return False
    for f in changed_files:
        if f in ANSIBLE_ONLY_EXACT:
            continue
        if any(f.startswith(p) for p in ANSIBLE_ONLY_PREFIXES):
            continue
        return False
    return True


def is_metadata_only(changed_files: list[str]) -> bool:
    """True if every changed file is in declared metadata paths.

    Deliberately bounded to explicit metadata prefixes/exact paths.
    We do not treat arbitrary '*.md' files outside those prefixes as
    metadata-only.
    """
    if not changed_files:
        return False

    for f in changed_files:
        if f in METADATA_ONLY_EXACT:
            continue
        if any(f.startswith(p) for p in METADATA_ONLY_PREFIXES):
            continue
        return False

    return True


def is_stacks_sha_only_push(changed_files: list[str]) -> bool:
    """True when a push only updates the stacks gitlink (+optional .gitmodules).

    This is a stacks SHA bump intent and should follow the tailscale-first
    full-reconcile path (host/config/health/portainer) without infra apply.
    """
    if not changed_files:
        return False

    if "stacks" not in changed_files:
        return False

    return all(f in STACKS_SHA_ONLY_EXACT for f in changed_files)


def compute_ansible_tags(changed_files: list[str]) -> str:
    """Derive comma-separated phase tags from changed role paths.

    Returns empty string (= full bootstrap) if any changed file is
    outside ansible/roles/ or maps to an unrecognized role.
    """
    if not changed_files:
        return ""

    for f in changed_files:
        if not f.startswith("ansible/roles/"):
            return ""

    tags: list[str] = []
    for f in changed_files:
        matched = False
        for prefix, tag in ROLE_PHASE_MAP.items():
            if f.startswith(prefix):
                if tag not in tags:
                    tags.append(tag)
                matched = True
                break
        if not matched:
            return ""

    return ",".join(tags)


# ---------------------------------------------------------------------------
# Main context computation
# ---------------------------------------------------------------------------


def compute_context(
    *,
    event_name: str,
    workflow_ansible_only: bool = False,
    push_before: str = "",
    push_sha: str = "",
    git: GitInterface | None = None,
) -> ExecutionContext:
    """Compute execution context from event data.

    This is a pure-logic function when a GitInterface is provided.
    Falls back to RealGit when git=None.
    """
    if git is None:
        git = RealGit()

    if event_name in ("push", "workflow_dispatch"):
        stacks_sha = git.rev_parse("HEAD:stacks")
        if not stacks_sha:
            raise RuntimeError(
                "Failed to resolve stacks gitlink SHA from HEAD:stacks."
            )

        if stacks_sha and not _SHA_RE.fullmatch(stacks_sha):
            raise RuntimeError(f"Invalid stacks SHA: {stacks_sha}")

        if event_name == "push":
            changed_files: list[str] = []
            if (
                push_before
                and push_before != _NULL_SHA
                and push_sha
            ):
                changed_files = git.diff_name_only(push_before, push_sha)

            metadata_only = is_metadata_only(changed_files)

            if metadata_only:
                return ExecutionContext(
                    run_infra_apply=False,
                    run_ansible_bootstrap=False,
                    run_portainer_apply=False,
                    run_host_sync=False,
                    run_config_sync=False,
                    run_health_redeploy=False,
                    stacks_sha=stacks_sha,
                    reason="infra-repo-metadata-only",
                )

            if is_stacks_sha_only_push(changed_files):
                return ExecutionContext(
                    run_infra_apply=False,
                    run_ansible_bootstrap=False,
                    run_portainer_apply=True,
                    run_host_sync=True,
                    run_config_sync=True,
                    run_health_redeploy=True,
                    stacks_sha=stacks_sha,
                    reason="infra-repo-stacks-sha-bump",
                )

            ansible_only = is_ansible_only(changed_files)

            if ansible_only:
                ansible_tags = compute_ansible_tags(changed_files)
                return ExecutionContext(
                    run_infra_apply=False,
                    run_ansible_bootstrap=True,
                    run_portainer_apply=True,
                    ansible_tags=ansible_tags,
                    stacks_sha=stacks_sha,
                    reason="infra-repo-push",
                )
            else:
                return ExecutionContext(
                    run_infra_apply=True,
                    run_ansible_bootstrap=True,
                    run_portainer_apply=True,
                    stacks_sha=stacks_sha,
                    reason="infra-repo-push",
                )

        else:  # workflow_dispatch
            return ExecutionContext(
                run_infra_apply=not workflow_ansible_only,
                run_ansible_bootstrap=True,
                run_portainer_apply=True,
                stacks_sha=stacks_sha,
                reason="manual-dispatch",
            )

    raise RuntimeError(f"Unsupported event: {event_name}")


# ---------------------------------------------------------------------------
# CLI: read env vars, emit to $GITHUB_OUTPUT
# ---------------------------------------------------------------------------


def _read_env_context() -> dict:
    """Read compute-context inputs from environment variables."""
    return {
        "event_name": os.environ.get("EVENT_NAME", ""),
        "workflow_ansible_only": os.environ.get("WORKFLOW_ANSIBLE_ONLY", "")
        == "true",
        "push_before": os.environ.get("PUSH_BEFORE", ""),
        "push_sha": os.environ.get("PUSH_SHA", ""),
    }


def _emit_outputs(ctx: ExecutionContext) -> None:
    """Write outputs to $GITHUB_OUTPUT (or stdout in local mode)."""
    lines = [
        f"run_infra_apply={'true' if ctx.run_infra_apply else 'false'}",
        f"run_ansible_bootstrap={'true' if ctx.run_ansible_bootstrap else 'false'}",
        f"run_portainer_apply={'true' if ctx.run_portainer_apply else 'false'}",
        f"run_host_sync={'true' if ctx.run_host_sync else 'false'}",
        f"run_config_sync={'true' if ctx.run_config_sync else 'false'}",
        f"run_health_redeploy={'true' if ctx.run_health_redeploy else 'false'}",
        f"has_work={'true' if ctx.has_work else 'false'}",
        f"stacks_sha={ctx.stacks_sha}",
        f"ansible_tags={ctx.ansible_tags}",
        f"reason={ctx.reason}",
    ]

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as f:
            for line in lines:
                f.write(line + "\n")
        print(
            f"Context emitted: reason={ctx.reason} has_work={ctx.has_work}"
        )
    else:
        for line in lines:
            print(line)


def main() -> None:
    env = _read_env_context()
    if not env["event_name"]:
        print("EVENT_NAME is required", file=sys.stderr)
        sys.exit(1)

    try:
        ctx = compute_context(**env)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

    _emit_outputs(ctx)


if __name__ == "__main__":
    main()
