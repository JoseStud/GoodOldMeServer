"""Shared fixtures for plan resolver tests."""

from __future__ import annotations

import json

import pytest

from ci_plan.git import GitInterface
from ci_plan.models import ResolveContext


class FakeGit:
    """Test double for GitInterface — returns pre-configured data."""

    def __init__(
        self,
        changed_files: list[str] | None = None,
        stacks_sha: str = "a" * 40,
        diff_error: Exception | None = None,
        rev_parse_error: Exception | None = None,
    ):
        self._changed_files = changed_files or []
        self._stacks_sha = stacks_sha
        self._diff_error = diff_error
        self._rev_parse_error = rev_parse_error

    def diff_name_only(self, before: str, after: str) -> list[str]:
        if self._diff_error:
            raise self._diff_error
        return self._changed_files

    def rev_parse(self, ref: str) -> str:
        if self._rev_parse_error:
            raise self._rev_parse_error
        return self._stacks_sha


DUMMY_SHA = "a" * 40
DUMMY_SHA_B = "b" * 40


def make_push_context(
    push_before: str = DUMMY_SHA,
    push_sha: str = DUMMY_SHA_B,
    **overrides: str | bool,
) -> ResolveContext:
    return ResolveContext(
        event_name="push",
        push_before=push_before,
        push_sha=push_sha,
        **overrides,
    )


def make_dispatch_context(
    stacks_sha: str = DUMMY_SHA,
    reason: str = "full-reconcile",
    source_repo: str = "example/stacks",
    source_run_id: str = "12345",
    source_sha: str = DUMMY_SHA,
    validate: bool = True,
    **overrides: str | bool,
) -> ResolveContext:
    payload = json.dumps({
        "schema_version": "v5",
        "stacks_sha": stacks_sha,
        "source_sha": source_sha,
        "source_repo": source_repo,
        "source_run_id": int(source_run_id) if source_run_id.isdigit() else source_run_id,
        "reason": reason,
    })
    return ResolveContext(
        event_name="repository_dispatch",
        payload_json=payload,
        payload_stacks_sha=stacks_sha,
        payload_reason=reason,
        payload_source_repo=source_repo,
        payload_source_run_id=source_run_id,
        payload_source_sha=source_sha,
        validate_dispatch_contract=validate,
        **overrides,
    )
