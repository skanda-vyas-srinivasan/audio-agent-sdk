"""Exercise launch, termination, and relaunch against the production Runtime.

Requires a logged-in macOS GUI session; does not capture audio or change TCC.
"""
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]


def wait_for(check, description, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(description)


with tempfile.TemporaryDirectory(prefix="sx-discovery-", dir="/tmp") as directory:
    base = Path(directory)
    bundle_id = "com.audioplane.discovery-test." + uuid.uuid4().hex
    app = base / "Discovery.app"
    executable = app / "Contents/MacOS/Discovery"
    executable.parent.mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": bundle_id,
                      "CFBundleExecutable": "Discovery",
                      "CFBundleName": "AudioPlane Discovery Test",
                      "CFBundlePackageType": "APPL"}, output)
    subprocess.run(["xcrun", "swiftc", str(ROOT / "Tests/RuntimeDiscovery/Application.swift"),
                    "-o", str(executable)], check=True)
    sockets = base / "s"
    pid_file = base / "application.pid"
    pids = set()
    previous_pid = None
    with (base / "runtime.log").open("w+") as log:
        runtime = subprocess.Popen([str(ROOT / ".build/debug/sonexis-runtime"),
                                    "--socket-dir", str(sockets)], stdout=log, stderr=log)
        try:
            wait_for(lambda: (sockets / "control.sock").exists(), "Runtime did not start")

            def sources():
                result = subprocess.run([str(ROOT / ".build/debug/sonexisctl"), "sources",
                                         "--json", "--socket", str(sockets / "control.sock")],
                                        check=True, capture_output=True, text=True, timeout=5)
                return [s for s in json.loads(result.stdout)
                        if s.get("bundle_identifier") == bundle_id]

            assert sources() == []  # Initialize NSWorkspace before the first launch.
            for _ in range(2):
                pid_file.unlink(missing_ok=True)
                subprocess.run(["open", "-g", "-n", str(app), "--args", str(pid_file)],
                               check=True)
                pid = int(wait_for(lambda: pid_file.read_text() if pid_file.exists() else None,
                                   "Discovery fixture did not launch"))
                pids.add(pid)
                assert pid != previous_pid, "Relaunch reused the old source PID"
                found = wait_for(sources, "Runtime did not discover an application launched later")
                assert found[0]["process_ids"] == [pid], found
                os.kill(pid, signal.SIGTERM)
                wait_for(lambda: not sources(), "Runtime still advertises a terminated application")
                pids.discard(pid)
                previous_pid = pid
            runtime.send_signal(signal.SIGTERM)
            assert runtime.wait(timeout=5) == 0, "Main-queue signal shutdown failed"
            print("Runtime application launch/termination/relaunch discovery passed")
        finally:
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if runtime.poll() is None:
                runtime.terminate()
                try:
                    runtime.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    runtime.kill()
                    runtime.wait(timeout=5)
