"""Core plan resolution logic — port of resolve_meta_plan.sh."""

from __future__ import annotations

import re
import sys

from .dispatch_validator import DispatchValidationError, validate_dispatch_payload
from .git import GitDiffError, GitInterface
from .models import PLAN_SCHEMA_VERSION, CIPlan, MetaPlan, ResolveContext, Stages
from .rules import ANSIBLE_ONLY_EXACT, ANSIBLE_ONLY_PREFIXES, ROLE_PHASE_MAP

_NULL_SHA = "0000000000000000000000000000000000000000"
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def is_ansible_only(changed_files: list[str]) -> bool:
    """True if every changed file is under ansible/** or is .ansible-lint."""
    if not changed_files:
        return False
    for f in changed_files:
        if f in ANSIBLE_ONLY_EXACT:
            continue
        if any(f.startswith(prefix) for prefix in ANSIBLE_ONLY_PREFIXES):
            continue
        return False
    return True


def compute_ansible_tags(changed_files: list[str]) -> str:
    """Map changed role paths to comma-separated phase tags.

    Returns empty string when a full bootstrap is required (changes outside
    ansible/roles/, no recognised phase, or empty input).
    """
    if not changed_files:
        return ""

    # Any change outside ansible/roles/ triggers full bootstrap.
    if any(not f.startswith("ansible/roles/") for f in changed_files):
        return ""

    phases: list[str] = []
    for role_prefix, phase_tag in ROLE_PHASE_MAP.items():
        if any(f.startswith(role_prefix) for f in changed_files):
            if phase_tag not in phases:
                phases.append(phase_tag)

    # No recognised phase mapping — fall back to full bootstrap.
    if not phases:
        return ""

    return ",".join(phases)


def _normalize_nullable(value: str) -> str:
    if not value or value == "null":
        return ""
    return value


def _is_valid_sha(sha: str) -> bool:
    return bool(_SHA_RE.match(sha))


def derive_stages(
    *,
    run_infra_apply: bool,
    run_ansible_bootstrap: bool,
    run_portainer_apply: bool,
    run_host_sync: bool,
    run_config_sync: bool,
    run_health_redeploy: bool,
    has_work: bool,
) -> Stages:
    """Pure boolean derivation of stage flags from run flags.

    Encodes the formulas from resolve_meta_plan.sh lines 194-219.
    """
    stage_inventory_handover = run_ansible_bootstrap or run_host_sync or run_config_sync

    return Stages(
        stage_cloud_runner_guard=has_work,
        stage_secret_validation=has_work,
        stage_network_policy_sync=has_work,
        stage_infra_apply=run_infra_apply,
        stage_inventory_handover=stage_inventory_handover,
        stage_network_preflight_ssh=stage_inventory_handover,
        stage_ansible_bootstrap=run_ansible_bootstrap,
        # host_sync is mutually exclusive with ansible_bootstrap
        stage_host_sync=run_host_sync and not run_ansible_bootstrap,
        stage_post_bootstrap_secret_check=run_portainer_apply,
        stage_portainer_api_preflight=run_portainer_apply or run_health_redeploy,
        stage_portainer_apply=run_portainer_apply,
        stage_config_sync=run_config_sync,
        stage_health_gated_redeploy=run_health_redeploy,
    )


def resolve_meta_plan(ctx: ResolveContext, git: GitInterface) -> CIPlan:
    """Compute the orchestrator execution plan from event context.

    This is the main entry point — a direct port of resolve_meta_mode() in
    resolve_meta_plan.sh.
    """
    if ctx.ci_plan_mode != "meta":
        print(f"Unsupported CI_PLAN_MODE: {ctx.ci_plan_mode}", file=sys.stderr)
        sys.exit(1)

    run_infra_apply = False
    run_ansible_bootstrap = False
    run_portainer_apply = False
    run_host_sync = False
    run_config_sync = False
    run_health_redeploy = False
    ansible_tags = ""
    stacks_sha = ""
    reason = ""

    if ctx.event_name in ("push", "workflow_dispatch", "dispatch_ansible_only"):
        try:
            stacks_sha = git.rev_parse("HEAD:stacks")
        except Exception:
            stacks_sha = ""
        if not stacks_sha:
            print(
                "Failed to resolve stacks gitlink SHA from HEAD:stacks for push event.",
                file=sys.stderr,
            )
            sys.exit(1)

        if ctx.event_name == "push":
            push_before = ctx.push_before
            push_sha = ctx.push_sha

            # Determine changed files for push events.
            changed_files: list[str] = []
            can_diff = bool(push_before) and push_before != _NULL_SHA and bool(push_sha)
            if can_diff:
                try:
                    changed_files = git.diff_name_only(push_before, push_sha)
                except GitDiffError as exc:
                    print(
                        f"Warning: git diff failed (falling back to full bootstrap): {exc}",
                        file=sys.stderr,
                    )
                    changed_files = []

            if changed_files and is_ansible_only(changed_files):
                run_infra_apply = False
                ansible_tags = compute_ansible_tags(changed_files)
            else:
                run_infra_apply = True

            run_ansible_bootstrap = True
            run_portainer_apply = True
            reason = "infra-repo-push"

        elif ctx.event_name == "workflow_dispatch":
            run_infra_apply = True
            run_ansible_bootstrap = True
            run_portainer_apply = True
            reason = "manual-dispatch"

        else:  # dispatch_ansible_only
            run_infra_apply = False
            run_ansible_bootstrap = True
            run_portainer_apply = True
            reason = "manual-dispatch"

    elif ctx.event_name == "repository_dispatch":
        if ctx.validate_dispatch_contract:
            validate_dispatch_payload(ctx)

        stacks_sha = _normalize_nullable(ctx.payload_stacks_sha)
        reason = _normalize_nullable(ctx.payload_reason)

        run_portainer_apply = True
        run_host_sync = True
        run_config_sync = True
        run_health_redeploy = True

    else:
        print(
            f"Unsupported EVENT_NAME for meta mode: {ctx.event_name}. "
            "Expected push, workflow_dispatch, dispatch_ansible_only, or repository_dispatch.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Reason fallback (same logic as resolve_meta_plan.sh lines 170-182).
    if not reason:
        if run_infra_apply:
            reason = "infra-reconcile"
        elif run_portainer_apply:
            reason = "portainer-reconcile"
        elif run_host_sync:
            reason = "host-runtime-sync"
        elif run_health_redeploy:
            reason = "content-change"
        else:
            reason = "no-op"

    # Validate stacks SHA if present.
    if stacks_sha and not _is_valid_sha(stacks_sha):
        print(f"Invalid stacks SHA: {stacks_sha}", file=sys.stderr)
        sys.exit(1)

    has_work = any([
        run_infra_apply,
        run_ansible_bootstrap,
        run_portainer_apply,
        run_host_sync,
        run_config_sync,
        run_health_redeploy,
    ])

    stages = derive_stages(
        run_infra_apply=run_infra_apply,
        run_ansible_bootstrap=run_ansible_bootstrap,
        run_portainer_apply=run_portainer_apply,
        run_host_sync=run_host_sync,
        run_config_sync=run_config_sync,
        run_health_redeploy=run_health_redeploy,
        has_work=has_work,
    )

    return CIPlan(
        plan_schema_version=PLAN_SCHEMA_VERSION,
        mode=ctx.ci_plan_mode,
        event_name=ctx.event_name,
        meta=MetaPlan(
            run_infra_apply=run_infra_apply,
            run_ansible_bootstrap=run_ansible_bootstrap,
            run_portainer_apply=run_portainer_apply,
            run_host_sync=run_host_sync,
            run_config_sync=run_config_sync,
            run_health_redeploy=run_health_redeploy,
            ansible_tags=ansible_tags,
            has_work=has_work,
            stacks_sha=stacks_sha,
            reason=reason,
            stages=stages,
        ),
    )
