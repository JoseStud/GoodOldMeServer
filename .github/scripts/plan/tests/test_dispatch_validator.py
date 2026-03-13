"""Dispatch payload validation tests — port of cases 5-7."""

from __future__ import annotations

import json

import pytest

from ci_plan.dispatch_validator import DispatchValidationError, validate_dispatch_payload

from .conftest import DUMMY_SHA, make_dispatch_context


class TestValidPayload:
    def test_valid_v5_payload_passes(self):
        ctx = make_dispatch_context()
        validate_dispatch_payload(ctx)

    def test_non_dispatch_event_skipped(self):
        from ci_plan.models import ResolveContext

        ctx = ResolveContext(event_name="push")
        validate_dispatch_payload(ctx)


class TestSchemaVersionRejection:
    """Case 5: validator rejects legacy v4 schema."""

    def test_v4_rejected(self):
        payload = json.dumps({
            "schema_version": "v4",
            "stacks_sha": DUMMY_SHA,
            "source_sha": DUMMY_SHA,
            "source_repo": "example/stacks",
            "source_run_id": 12345,
            "reason": "full-reconcile",
        })
        ctx = make_dispatch_context()
        # Override payload_json with v4 schema
        ctx = ctx.__class__(
            event_name="repository_dispatch",
            payload_json=payload,
            payload_stacks_sha=DUMMY_SHA,
            payload_reason="full-reconcile",
            payload_source_repo="example/stacks",
            payload_source_run_id="12345",
            payload_source_sha=DUMMY_SHA,
            validate_dispatch_contract=True,
        )
        with pytest.raises(DispatchValidationError, match="v4"):
            validate_dispatch_payload(ctx)


class TestReasonRejection:
    """Case 6: validator rejects wrong reason."""

    def test_wrong_reason_rejected(self):
        ctx = make_dispatch_context(reason="manual-refresh")
        with pytest.raises(DispatchValidationError, match="manual-refresh"):
            validate_dispatch_payload(ctx)


class TestRemovedFieldRejection:
    """Case 7: validator rejects removed selective fields."""

    def test_changed_stacks_in_payload_shape(self):
        payload = json.dumps({
            "schema_version": "v5",
            "stacks_sha": DUMMY_SHA,
            "source_sha": DUMMY_SHA,
            "source_repo": "example/stacks",
            "source_run_id": 12345,
            "reason": "full-reconcile",
            "changed_stacks": ["gateway"],
        })
        ctx = make_dispatch_context()
        ctx = ctx.__class__(
            event_name="repository_dispatch",
            payload_json=payload,
            payload_stacks_sha=DUMMY_SHA,
            payload_reason="full-reconcile",
            payload_source_repo="example/stacks",
            payload_source_run_id="12345",
            payload_source_sha=DUMMY_SHA,
            validate_dispatch_contract=True,
        )
        with pytest.raises(DispatchValidationError, match="must contain only"):
            validate_dispatch_payload(ctx)

    def test_removed_env_fields_rejected(self):
        ctx = make_dispatch_context()
        extra_env = {"PAYLOAD_CHANGED_STACKS": "gateway"}
        with pytest.raises(DispatchValidationError, match="removed"):
            validate_dispatch_payload(ctx, extra_env=extra_env)


class TestShaValidation:
    def test_invalid_stacks_sha(self):
        ctx = make_dispatch_context(stacks_sha="not-a-sha")
        with pytest.raises(DispatchValidationError, match="stacks_sha"):
            validate_dispatch_payload(ctx)

    def test_empty_stacks_sha(self):
        ctx = make_dispatch_context(stacks_sha="")
        with pytest.raises(DispatchValidationError, match="stacks_sha"):
            validate_dispatch_payload(ctx)

    def test_invalid_source_sha(self):
        ctx = make_dispatch_context(source_sha="xyz")
        with pytest.raises(DispatchValidationError, match="source_sha"):
            validate_dispatch_payload(ctx)


class TestSourceRepoValidation:
    def test_invalid_source_repo(self):
        ctx = make_dispatch_context(source_repo="not a repo")
        with pytest.raises(DispatchValidationError, match="source_repo"):
            validate_dispatch_payload(ctx)


class TestSourceRunIdValidation:
    def test_non_numeric_run_id(self):
        ctx = make_dispatch_context(source_run_id="abc")
        with pytest.raises(DispatchValidationError, match="source_run_id"):
            validate_dispatch_payload(ctx)
