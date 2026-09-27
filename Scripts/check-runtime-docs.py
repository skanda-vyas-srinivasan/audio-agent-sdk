#!/usr/bin/env python3
"""Validate local Markdown links and current Runtime documentation versions."""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION = (ROOT / "RUNTIME_VERSION").read_text(encoding="utf-8").strip()
SERIES = ".".join(VERSION.split(".")[:2])


def markdown_files() -> list[pathlib.Path]:
    output = subprocess.check_output(
        [
            "git",
            "-C",
            str(ROOT),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "*.md",
        ],
        text=True,
    )
    return [ROOT / line for line in output.splitlines() if line]


def check_current_versions() -> list[str]:
    checks = {
        "docs/sonexis-runtime.md": rf"^# Sonexis Runtime v{re.escape(SERIES)}$",
        "SDKs/python/README.md": rf"Runtime v{re.escape(SERIES)}\b",
        "SDKs/typescript/README.md": rf"Version {re.escape(SERIES)}\b",
    }
    failures = []
    for relative, pattern in checks.items():
        text = (ROOT / relative).read_text(encoding="utf-8")
        if re.search(pattern, text, flags=re.MULTILINE) is None:
            failures.append(f"{relative}: does not identify the current v{SERIES} release")
    return failures


def check_local_links(files: list[pathlib.Path]) -> list[str]:
    failures = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        # Code examples often contain language syntax that resembles Markdown.
        text = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
        for match in re.finditer(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", text):
            link = match.group(1).strip()
            if link.startswith("<") and link.endswith(">"):
                link = link[1:-1]
            if not link or link.startswith(("#", "http://", "https://", "mailto:")):
                continue
            target = urllib.parse.unquote(link.split("#", 1)[0].split("?", 1)[0])
            destination = (
                ROOT / target.lstrip("/")
                if target.startswith("/")
                else path.parent / target
            )
            if not destination.exists():
                relative = path.relative_to(ROOT)
                failures.append(f"{relative}: missing local link target {link!r}")
    return failures


def main() -> None:
    failures = check_current_versions() + check_local_links(markdown_files())
    if failures:
        for failure in failures:
            print(f"runtime-docs-check: {failure}", file=sys.stderr)
        raise SystemExit(1)
    print(f"Runtime v{SERIES} documentation versions and local links passed")


if __name__ == "__main__":
    main()
