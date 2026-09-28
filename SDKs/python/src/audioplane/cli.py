"""Command-line client installed by the AudioPlane Python distribution."""

import argparse
import asyncio
from dataclasses import asdict, is_dataclass
from enum import Enum
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Callable, Optional, Sequence
import wave

from sonexis import (AudioFormat, AudioOutputDestination, AudioSource, RuntimeStatus,
                     SampleFormat, Sonexis)
from sonexis.errors import SonexisError

from . import __version__


_AUDIOPLANE_INPUT_ID = "coreaudio:com.audioplane.input.device"
_SPEAK_FORMAT = AudioFormat(
    sample_rate=48_000,
    channels=1,
    sample_format=SampleFormat.PCM_S16LE,
)


class SpeechSynthesisError(RuntimeError):
    """Raised when the local macOS speech synthesizer cannot produce PCM."""


def _positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _buffer_milliseconds(value: str) -> int:
    parsed = int(value)
    if not 20 <= parsed <= 250:
        raise argparse.ArgumentTypeError("must be between 20 and 250")
    return parsed


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
        ("sources", "list available application and microphone audio sources"),
        ("outputs", "list available audio output destinations"),
        ("version", "show the installed SDK version"),
    ):
        child = subcommands.add_parser(command, help=help_text)
        child.add_argument("--json", action="store_true", help="emit machine-readable JSON")

    speak = subcommands.add_parser(
        "speak",
        help="type text interactively and send macOS speech to an audio destination",
    )
    speak.add_argument(
        "--destination",
        default=_AUDIOPLANE_INPUT_ID,
        help="output destination ID or name (default: AudioPlane Input)",
    )
    speak.add_argument("--voice", help="macOS voice name passed to say")
    speak.add_argument(
        "--rate",
        type=_positive_integer,
        help="speech rate in words per minute",
    )
    speak.add_argument(
        "--buffer-ms",
        type=_buffer_milliseconds,
        default=60,
        help="Runtime target buffer in milliseconds (20-250; default: 60)",
    )
    microphone = subcommands.add_parser(
        "mic-through",
        help="forward a physical microphone into AudioPlane Input until interrupted",
    )
    microphone.add_argument(
        "--source",
        help="microphone source ID or exact name (default: current macOS input)",
    )
    microphone.add_argument(
        "--destination",
        default=_AUDIOPLANE_INPUT_ID,
        help="output destination ID or name (default: AudioPlane Input)",
    )
    microphone.add_argument(
        "--buffer-ms",
        type=_buffer_milliseconds,
        default=60,
        help="Runtime target buffer in milliseconds (20-250; default: 60)",
    )
    return parser


def _command_failure(tool: str, result: subprocess.CompletedProcess) -> SpeechSynthesisError:
    message = (result.stderr or result.stdout or "unknown error").strip()
    return SpeechSynthesisError(f"{tool} failed: {message}")


def _synthesize_speech(text: str, voice: Optional[str], rate: Optional[int]) -> bytes:
    """Render one line with macOS ``say`` as PCM16 mono at 48 kHz."""
    say = shutil.which("say")
    afconvert = shutil.which("afconvert")
    if say is None or afconvert is None:
        missing = "say" if say is None else "afconvert"
        raise SpeechSynthesisError(
            f"macOS speech tool {missing!r} is unavailable; speak requires macOS")

    with tempfile.TemporaryDirectory(prefix="audioplane-speak-") as directory:
        source = Path(directory) / "speech.aiff"
        converted = Path(directory) / "speech.wav"
        say_command = [say]
        if voice:
            say_command.extend(["-v", voice])
        if rate is not None:
            say_command.extend(["-r", str(rate)])
        say_command.extend(["-o", str(source), text])

        try:
            result = subprocess.run(
                say_command, capture_output=True, text=True, check=False)
        except OSError as error:
            raise SpeechSynthesisError(f"could not run say: {error}") from error
        if result.returncode != 0:
            raise _command_failure("say", result)

        try:
            result = subprocess.run(
                [
                    afconvert,
                    "-f", "WAVE",
                    "-d", "LEI16@48000",
                    "-c", "1",
                    str(source),
                    str(converted),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as error:
            raise SpeechSynthesisError(f"could not run afconvert: {error}") from error
        if result.returncode != 0:
            raise _command_failure("afconvert", result)

        try:
            with wave.open(str(converted), "rb") as stream:
                actual = (
                    stream.getframerate(),
                    stream.getnchannels(),
                    stream.getsampwidth(),
                    stream.getcomptype(),
                )
                expected = (48_000, 1, 2, "NONE")
                if actual != expected:
                    raise SpeechSynthesisError(
                        "speech conversion produced an unexpected audio format "
                        f"(rate={actual[0]}, channels={actual[1]}, bytes={actual[2]}, "
                        f"compression={actual[3]})")
                pcm = stream.readframes(stream.getnframes())
        except (OSError, EOFError, wave.Error) as error:
            raise SpeechSynthesisError(f"could not read synthesized speech: {error}") from error
        if not pcm:
            raise SpeechSynthesisError("macOS speech synthesis produced no audio")
        return pcm


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
    print(f"{'ID':<46}  {'NAME':<24}  {'KIND':<12}  {'STATUS':<10}  PID")
    for source in sources:
        pids = ",".join(str(pid) for pid in source.process_ids) or "-"
        status = "active" if source.available else source.process_state
        if source.is_default:
            status += ",default"
        print(f"{_safe(source.id):<46}  {_safe(source.name):<24}  "
              f"{_safe(source.kind):<12}  {_safe(status):<10}  {pids}")


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


async def _run_speak(
    client: Any,
    arguments: argparse.Namespace,
    line_reader: Callable[[str], str],
    synthesizer: Callable[[str, Optional[str], Optional[int]], bytes],
) -> int:
    output = await client.playback(
        destination=arguments.destination,
        format=_SPEAK_FORMAT,
        target_buffer_milliseconds=arguments.buffer_ms,
    )
    async with output:
        destination = getattr(output, "destination", None)
        destination_name = getattr(destination, "name", arguments.destination)
        print(f"{_safe(destination_name)} ready. Type text and press Enter; /quit exits.")
        while True:
            try:
                line = line_reader("> ")
            except EOFError:
                print()
                break
            text = line.strip()
            if text.lower() in {"/quit", "/exit"}:
                break
            if not text:
                continue
            try:
                pcm = synthesizer(text, arguments.voice, arguments.rate)
            except SpeechSynthesisError as error:
                print(f"audioplane: speak: {_safe(error)}", file=sys.stderr)
                continue
            await output.write(pcm)
    return 0


async def _run_microphone_passthrough(client: Any, arguments: argparse.Namespace) -> int:
    passthrough = client.microphone_passthrough(
        arguments.source,
        output_destination=arguments.destination,
        format=_SPEAK_FORMAT,
        target_buffer_milliseconds=arguments.buffer_ms,
    )
    async with passthrough:
        assert passthrough.source is not None
        assert passthrough.output is not None
        destination = passthrough.output.destination
        destination_name = destination.name if destination else arguments.destination
        print(
            f"Forwarding {_safe(passthrough.source.name)} to "
            f"{_safe(destination_name)}. Press Ctrl-C to stop."
        )
        await passthrough.wait()
    return 0


async def _run(
    arguments: argparse.Namespace,
    client_type: Any = Sonexis,
    *,
    line_reader: Callable[[str], str] = input,
    synthesizer: Callable[[str, Optional[str], Optional[int]], bytes] = _synthesize_speech,
) -> int:
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

        if arguments.command == "speak":
            return await _run_speak(client, arguments, line_reader, synthesizer)

        if arguments.command == "mic-through":
            return await _run_microphone_passthrough(client, arguments)

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
