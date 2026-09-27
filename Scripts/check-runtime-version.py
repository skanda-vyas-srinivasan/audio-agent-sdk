#!/usr/bin/env python3
"""Fail when checked-in Runtime/SDK release versions disagree."""

import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
EXPECTED = (ROOT / "RUNTIME_VERSION").read_text(encoding="utf-8").strip()


def require_version(path: str, pattern: str, expected_count: int = 1) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if len(matches) != expected_count:
        raise AssertionError(
            f"{path}: expected {expected_count} version field(s), found {len(matches)}"
        )
    wrong = [value for value in matches if value != EXPECTED]
    if wrong:
        raise AssertionError(f"{path}: expected {EXPECTED}, found {wrong}")


def main() -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", EXPECTED):
        raise AssertionError(f"RUNTIME_VERSION is not semantic: {EXPECTED!r}")

    require_version(
        "Sources/SonexisRuntime/IPC/RuntimeProtocol.swift",
        r'runtimeVersion = "([^"]+)"',
    )
    require_version(
        "Distribution/Runtime-Embedded-Info.plist",
        r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>",
    )

    require_version("SDKs/python/pyproject.toml", r'^version = "([^"]+)"$', 1)
    require_version("SDKs/python/setup.py", r'version="([^"]+)"', 1)
    require_version("SDKs/python/src/sonexis/client.py", r'client_version: str = "([^"]+)"', 1)
    require_version("SDKs/python/src/sonexis/mcp_server.py", r'client_version="([^"]+)"', 1)
    require_version("SDKs/python/src/sonexis/mcp_server.py", r'^\s*version="([^"]+)"', 1)
    require_version("SDKs/python/src/sonexis/__init__.py", r'__version__ = "([^"]+)"', 1)
    require_version("SDKs/typescript/src/index.ts", r'client_version: "([^"]+)"', 1)

    if int(EXPECTED.split(".", 1)[0]) >= 1:
        stable_classifier = "Development Status :: 5 - Production/Stable"
        for path in ("SDKs/python/pyproject.toml", "SDKs/python/setup.py"):
            text = (ROOT / path).read_text(encoding="utf-8")
            if stable_classifier not in text or "Development Status :: 4 - Beta" in text:
                raise AssertionError(f"{path}: 1.x package must declare Production/Stable")

    package = json.loads((ROOT / "SDKs/typescript/package.json").read_text(encoding="utf-8"))
    lock = json.loads((ROOT / "SDKs/typescript/package-lock.json").read_text(encoding="utf-8"))
    values = [package.get("version"), lock.get("version"), lock.get("packages", {}).get("", {}).get("version")]
    if values != [EXPECTED, EXPECTED, EXPECTED]:
        raise AssertionError(f"TypeScript package versions disagree: {values}")

    print(f"Runtime release versions agree: {EXPECTED}")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError) as error:
        print(f"runtime-version-check: {error}", file=sys.stderr)
        raise SystemExit(1)
