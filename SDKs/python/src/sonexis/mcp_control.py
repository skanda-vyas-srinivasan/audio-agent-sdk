"""Dependency-free tool dispatch behind the optional Sonexis MCP server."""

from dataclasses import asdict, is_dataclass
from enum import Enum
from typing import Any, Dict, Optional, Set

from .client import Sonexis
from .errors import SonexisError
from .models import AudioFormat


def _jsonable(value: Any) -> Any:
    if is_dataclass(value):
        return {key: _jsonable(item) for key, item in asdict(value).items()}
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _capture_json(value: Any) -> Dict[str, Any]:
    """Serialize capture state without exposing the binary socket capability."""
    result = _jsonable(value)
    if not isinstance(result, dict):
        raise SonexisError("invalid_session", "Runtime returned invalid capture state")
    result.pop("data_socket_path", None)
    return result


class SonexisControlTools:
    """Low-bandwidth agent controls. This class never reads or returns PCM."""

    def __init__(self, client: Sonexis, *, allow_capture: bool = False) -> None:
        self.client = client
        self.allow_capture = allow_capture
        self._owned_capture_ids: Set[str] = set()

    async def runtime_info(self) -> Dict[str, Any]:
        handshake = self.client.handshake
        if handshake is None:
            raise SonexisError("not_connected", "Connect to Sonexis Runtime first")
        return {
            "protocol_version": handshake.protocol_version,
            "runtime_version": handshake.runtime_version,
            "runtime_instance_id": handshake.runtime_instance_id,
            "capabilities": list(handshake.capabilities),
            "limits": dict(handshake.limits),
            "capture_control_enabled": self.allow_capture,
            "mcp_transports_audio": False,
        }

    async def list_sources(self) -> Dict[str, Any]:
        return {"sources": _jsonable(await self.client.sources())}

    async def get_source(self, selector: str = "", pid: Optional[int] = None) -> Dict[str, Any]:
        if selector and pid is not None:
            raise SonexisError("invalid_argument", "Provide selector or pid, not both")
        if len(selector) > 512:
            raise SonexisError("invalid_argument", "selector is too long")
        if pid is not None and (isinstance(pid, bool) or pid < 1 or pid > 2_147_483_647):
            raise SonexisError("invalid_argument", "pid must be a positive process ID")
        value = pid if pid is not None else selector
        if value == "":
            raise SonexisError("invalid_argument", "selector or pid is required")
        return {"source": _jsonable(await self.client.get_source(value))}

    async def get_diagnostics(self) -> Dict[str, Any]:
        return {"status": _jsonable(await self.client.status())}

    async def list_output_destinations(self) -> Dict[str, Any]:
        return {"destinations": _jsonable(await self.client.output_destinations())}

    async def list_sessions(self) -> Dict[str, Any]:
        sessions = []
        stale = []
        for session_id in sorted(self._owned_capture_ids):
            try:
                sessions.append(_capture_json(await self.client.status(session_id)))
            except SonexisError as error:
                if error.code in {"session_not_found", "unknown_session"}:
                    stale.append(session_id)
                    continue
                raise
        self._owned_capture_ids.difference_update(stale)
        return {"sessions": sessions}

    async def get_session(self, session_id: str) -> Dict[str, Any]:
        self._require_owned_session(session_id)
        return {"session": _capture_json(await self.client.status(session_id))}

    async def start_capture(self, source: str, format_profile: str = "speech_16k") -> Dict[str, Any]:
        self._require_capture_control()
        profiles = {
            "speech_16k": AudioFormat.speech_16k,
            "openai_realtime": AudioFormat.openai_realtime,
            "gemini_live": AudioFormat.gemini_live,
        }
        factory = profiles.get(format_profile)
        if factory is None:
            raise SonexisError("invalid_format_profile",
                               f"Unknown format profile: {format_profile}")
        info = await self.client.create_capture(source, format=factory())
        self._owned_capture_ids.add(info.id)
        return {
            "session": _capture_json(info),
            "audio_delivery": "Use Sonexis.attach_capture(session_id) over the binary data plane; MCP never carries PCM.",
        }

    async def stop_capture(self, session_id: str) -> Dict[str, Any]:
        self._require_capture_control()
        self._require_owned_session(session_id)
        try:
            return {"session": _capture_json(await self.client.stop(session_id))}
        finally:
            self._owned_capture_ids.discard(session_id)

    def _require_owned_session(self, session_id: str) -> None:
        if session_id not in self._owned_capture_ids:
            raise SonexisError(
                "mcp_session_not_owned",
                "This MCP process can only inspect or stop captures it started",
            )

    def _require_capture_control(self) -> None:
        if not self.allow_capture:
            raise SonexisError(
                "capture_control_disabled",
                "Start the MCP server with --allow-capture to enable capture mutation",
            )
