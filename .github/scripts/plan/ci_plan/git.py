"""Git interface with protocol-based injection for testability."""

from __future__ import annotations

import subprocess
from typing import Protocol


class GitInterface(Protocol):
    def diff_name_only(self, before: str, after: str) -> list[str]: ...

    def rev_parse(self, ref: str) -> str: ...


class RealGit:
    """Subprocess-backed git operations."""

    def diff_name_only(self, before: str, after: str) -> list[str]:
        result = subprocess.run(
            ["git", "diff", "--name-only", before, after],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise GitDiffError(result.stderr.strip())
        return [f for f in result.stdout.strip().split("\n") if f]

    def rev_parse(self, ref: str) -> str:
        result = subprocess.run(
            ["git", "rev-parse", ref],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise GitRevParseError(result.stderr.strip())
        return result.stdout.strip()


class GitDiffError(Exception):
    pass


class GitRevParseError(Exception):
    pass
