"""Shared fixtures for ci_pipeline tests."""

from __future__ import annotations

from dataclasses import dataclass, field

import pytest

from ci_pipeline.context import GitInterface

DUMMY_SHA = "a" * 40
DUMMY_SHA_B = "b" * 40


@dataclass
class FakeGit:
    """Test double for GitInterface."""

    stacks_sha: str = DUMMY_SHA
    changed_files: list[str] = field(default_factory=list)

    def diff_name_only(self, before: str, after: str) -> list[str]:
        return self.changed_files

    def rev_parse(self, ref: str) -> str:
        if ref == "HEAD:stacks":
            return self.stacks_sha
        return ""


@pytest.fixture
def fake_git() -> FakeGit:
    return FakeGit()
