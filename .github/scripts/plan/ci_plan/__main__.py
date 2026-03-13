"""CLI entry point: python3 -m ci_plan."""

from __future__ import annotations

import sys

from .dispatch_validator import DispatchValidationError
from .git import RealGit
from .github_actions import emit_output, read_env_context
from .resolver import resolve_meta_plan


def main() -> None:
    local_mode = "--local" in sys.argv

    ctx = read_env_context()

    if not ctx.event_name:
        print("EVENT_NAME is required", file=sys.stderr)
        sys.exit(1)

    git = RealGit()
    try:
        plan = resolve_meta_plan(ctx, git)
    except DispatchValidationError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    plan_json = plan.to_json()

    if local_mode:
        print(plan_json)
    else:
        emit_output("plan_json", plan_json)
        print(f"Plan emitted: reason={plan.meta.reason} has_work={plan.meta.has_work}")


if __name__ == "__main__":
    main()
