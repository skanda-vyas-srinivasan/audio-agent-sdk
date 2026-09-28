"""Command-line client installed by the AudioPlane Python distribution."""

import argparse
import asyncio
from dataclasses import asdict, is_dataclass
from enum import Enum
import json
import os
import sys
from typing import Any, Optional, Sequence

from sonexis import AudioOutputDestination, AudioSource, RuntimeStatus, Sonexis
from sonexis.errors import SonexisError

from . import __version__


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="audioplane",
        description="Inspect and control the local AudioPlane macOS audio Runtime.",
    )
    parser.add_argument(
        "--socket",
        help="Runtime control socket (defaults to AUDIOPLANE_RUNTIME_SOCKET or the standard path)",
    )
    subcommands = parser.add_subparsers(dest="command", required=True)

    for command, help_text in (
        ("doctor", "check SDK and Runtime connectivity"),
        ("status", "show Runtime health and aggregate metrics"),
        ("sources", "list available application audio sources"),
        ("outputs", "list available audio output destinations"),
        ("version", "show the installed SDK version"),
    ):
        child = subcommands.add_parser(command, help=help_text)
        child.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    return parser


def _jsonable(value: Any) -> Any:
    if is_dataclass(value):
        return _jsonable(asdict(value))
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _print_json(value: Any) -> None:
    print(json.dumps(_jsonable(value), indent=2, sort_keys=True))


def _safe(value: Any) -> str:
    text = str(value)
    return "".join(
        character if character >= " " and character != "\x7f"
        else f"\\x{ord(character):02x}"
        for character in text
    )


def _socket_path(argument: Optional[str]) -> Optional[str]:
    return argument or os.environ.get("AUDIOPLANE_RUNTIME_SOCKET")


def _print_sources(sources: Sequence[AudioSource]) -> None:
    print(f"{'ID':<36}  {'APP':<24}  {'STATUS':<10}  PID")
    for source in sources:
        pids = ",".join(str(pid) for pid in source.process_ids) or "-"
        status = "active" if source.available else source.process_state
        print(f"{_safe(source.id):<36}  {_safe(source.name):<24}  "
              f"{_safe(status):<10}  {pids}")


def _print_outputs(outputs: Sequence[AudioOutputDestination]) -> None:
    print(f"{'ID':<40}  {'DESTINATION':<28}  {'KIND':<14}  STATUS")
    for output in outputs:
        status = "available" if output.available else "unavailable"
        if output.is_default:
            status += ",default"
        print(f"{_safe(output.id):<40}  {_safe(output.name):<28}  "
              f"{_safe(output.kind):<14}  {status}")


def _print_status(status: RuntimeStatus) -> None:
    uptime_seconds = status.uptime_ns / 1_000_000_000
    print(f"Runtime {status.runtime_version} ({_safe(status.runtime_instance_id)})")
    print(f"uptime={uptime_seconds:.1f}s clients={status.active_clients} "
          f"captures={status.active_sessions} outputs={status.active_output_sessions}")
    print(f"capture_frames={status.total_frames_forwarded} "
          f"capture_dropped={status.total_dropped_frames} "
          f"output_frames={status.total_output_frames_rendered} "
          f"output_dropped={status.total_output_frames_dropped}")


async def _run(arguments: argparse.Namespace, client_type: Any = Sonexis) -> int:
    if arguments.command == "version":
        payload = {"name": "AudioPlane", "sdk_version": __version__}
        _print_json(payload) if arguments.json else print(f"AudioPlane {__version__}")
        return 0

    socket_path = _socket_path(arguments.socket)
    async with client_type(
        socket_path,
        client_name="audioplane-cli",
        client_version=__version__,
    ) as client:
        if arguments.command == "doctor":
            handshake = client.handshake
            assert handshake is not None
            payload = {
                "ok": True,
                "sdk_version": __version__,
                "protocol_version": handshake.protocol_version,
                "runtime_version": handshake.runtime_version,
                "runtime_instance_id": handshake.runtime_instance_id,
                "socket_path": client.socket_path,
                "capabilities": handshake.capabilities,
            }
            if arguments.json:
                _print_json(payload)
            else:
                print(f"AudioPlane SDK {__version__}: ok")
                print(f"Runtime {handshake.runtime_version}: ok")
                print(f"Protocol v{handshake.protocol_version}: compatible")
                print(f"Socket: {_safe(client.socket_path)}")
            return 0

        if arguments.command == "sources":
            values = await client.sources()
            _print_json(values) if arguments.json else _print_sources(values)
            return 0

        if arguments.command == "outputs":
            values = await client.output_destinations()
            _print_json(values) if arguments.json else _print_outputs(values)
            return 0

        if arguments.command == "status":
            value = await client.status()
            assert isinstance(value, RuntimeStatus)
            _print_json(value) if arguments.json else _print_status(value)
            return 0

    raise AssertionError(f"unhandled command: {arguments.command}")


def main(argv: Optional[Sequence[str]] = None) -> None:
    arguments = _parser().parse_args(argv)
    try:
        result = asyncio.run(_run(arguments))
    except SonexisError as error:
        if getattr(arguments, "json", False):
            _print_json({
                "ok": False,
                "error": {
                    "code": error.code,
                    "message": error.message,
                    "retryable": error.retryable,
                    "details": error.details,
                },
            })
        else:
            print(f"audioplane: {_safe(error.code)}: {_safe(error.message)}", file=sys.stderr)
            if error.code in {"runtime_unavailable", "connect_failed"}:
                print("Start the signed local AudioPlane Runtime, then retry.", file=sys.stderr)
        raise SystemExit(1) from error
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    raise SystemExit(result)


if __name__ == "__main__":
    main()
