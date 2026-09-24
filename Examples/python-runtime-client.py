#!/usr/bin/env python3
"""Minimal dependency-free Sonexis Runtime client."""

import json
import os
import socket
import struct
import sys
import uuid


def request(control, reader, command, **fields):
    request_id = str(uuid.uuid4())
    payload = {"version": 1, "requestID": request_id, "command": command, **fields}
    control.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
    line = reader.readline()
    if not line:
        raise EOFError("Sonexis Runtime disconnected")
    response = json.loads(line)
    if not response.get("ok"):
        raise RuntimeError(response.get("error", {}).get("message", "Runtime request failed"))
    return response


def main():
    control_path = os.environ.get(
        "SONEXIS_RUNTIME_SOCKET", f"/tmp/sonexis-runtime-{os.getuid()}/control.sock"
    )
    control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    control.connect(control_path)
    reader = control.makefile("rb")
    sources = request(control, reader, "list_sources").get("sources", [])
    if not sources:
        raise RuntimeError("No active application audio sources")
    if len(sys.argv) > 1:
        source = next((item for item in sources if item["id"] == sys.argv[1]), None)
        if source is None:
            raise RuntimeError(f"Source not found: {sys.argv[1]}")
    else:
        source = sources[0]
    session = request(control, reader, "start_capture", sourceID=source["id"])["session"]
    print(f"capturing {source['name']} as {session['id']}", file=sys.stderr)

    data = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    data.connect(session["dataSocketPath"])
    header = struct.Struct(">IHHIIQQIIHH")
    received = 0
    try:
        while received < 50:
            raw = b""
            while len(raw) < header.size:
                chunk = data.recv(header.size - len(raw))
                if not chunk:
                    return
                raw += chunk
            magic, version, _, header_size, payload_size, sequence, timestamp, rate, frames, channels, bits = header.unpack(raw)
            if magic != 0x53585043 or version != 1 or header_size != header.size:
                raise RuntimeError("Invalid PCM frame header")
            payload = b""
            while len(payload) < payload_size:
                chunk = data.recv(payload_size - len(payload))
                if not chunk:
                    raise EOFError("Sonexis Runtime disconnected during a PCM frame")
                payload += chunk
            print(f"frame={sequence} samples={frames} bytes={len(payload)} rate={rate} channels={channels} bits={bits} t={timestamp}")
            received += 1
    finally:
        request(control, reader, "stop_capture", sessionID=session["id"])
        data.close()
        reader.close()
        control.close()


if __name__ == "__main__":
    main()
