#!/usr/bin/env python3
"""Prove AudioPlane is self-contained and carries no Sonexis App dependency."""

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def git(*arguments: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(ROOT), *arguments], text=True
    ).strip()


def fail(message: str) -> None:
    print(f"repository-independence-check: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    for remote in git("remote").splitlines():
        urls = git("remote", "get-url", "--all", remote).splitlines()
        for url in urls:
            repository_name = url.rstrip("/").rsplit("/", 1)[-1]
            if repository_name.endswith(".git"):
                repository_name = repository_name[:-4]
            if repository_name.lower() != "audioplane":
                fail(f"unexpected remote repository for {remote}: {url}")

    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    if '.package(path: "SonexisAudioEngine")' not in package:
        fail("Runtime must use its repository-owned engine package")
    if ".package(url:" in package:
        fail("Runtime unexpectedly depends on an external Swift package URL")

    forbidden_current = (
        ROOT / "Sonexis.xcodeproj",
        ROOT / "Sonexis",
        ROOT / "ENGINE_PROVENANCE.json",
    )
    for path in forbidden_current:
        if path.exists() or path.is_symlink():
            fail(f"consumer-App or shared-engine artifact exists: {path.name}")

    ignored_roots = {".git", ".build", ".swiftpm", "node_modules", ".venv"}
    for path in ROOT.rglob("*"):
        relative = path.relative_to(ROOT)
        if any(part in ignored_roots for part in relative.parts):
            continue
        if path.is_symlink():
            fail(f"repository contains a filesystem link: {relative}")

    historical_paths = git("log", "--all", "--format=", "--name-only").splitlines()
    forbidden_history = (
        "Sonexis/AudioEngine/",
        "Sonexis/CanvasView/",
        "Sonexis/Models/",
        "Sonexis.xcodeproj/",
    )
    for path in historical_paths:
        if path.startswith(forbidden_history):
            fail(f"filtered history leaked consumer-App path: {path}")

    print("Standalone Runtime repository independence passed")


if __name__ == "__main__":
    main()
