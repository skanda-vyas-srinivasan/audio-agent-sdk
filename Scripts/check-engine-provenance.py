#!/usr/bin/env python3
"""Verify the committed engine snapshot matches its provenance manifest."""

import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "ENGINE_PROVENANCE.json").read_text())


def git(*arguments: str, cwd: Path = ROOT) -> str:
    return subprocess.check_output(
        ["git", "-C", str(cwd), *arguments], text=True
    ).strip()


def main() -> None:
    expected = MANIFEST["git_tree"]
    actual = git("rev-parse", "HEAD:SonexisAudioEngine")
    if actual != expected:
        raise RuntimeError(f"engine snapshot tree is {actual}, expected {expected}")
    if git("status", "--porcelain", "--", "SonexisAudioEngine"):
        raise RuntimeError("engine snapshot has uncommitted changes")

    source_value = os.environ.get("SONEXIS_ENGINE_SOURCE")
    if source_value:
        source = Path(source_value).resolve()
        source_commit = MANIFEST["source_commit"]
        source_path = MANIFEST["source_path"]
        source_tree = git("rev-parse", f"{source_commit}:{source_path}", cwd=source)
        if source_tree != expected:
            raise RuntimeError(
                f"source {source_commit}:{source_path} is {source_tree}, expected {expected}"
            )
    print(f"Engine snapshot provenance passed: {expected}")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"engine-provenance-check: {error}", file=sys.stderr)
        raise SystemExit(1)
