"""Dependency-free tool dispatch behind the optional Sonexis MCP server."""

from dataclasses import asdict, is_dataclass
from enum import Enum
from typing import Any, Dict, Optional

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


class SonexisControlTools:
    """Low-bandwidth agent controls. This class never reads or returns PCM."""

    def __init__(self, client: Sonexis, *, allow_capture: bool = False) -> None:
        self.client = client
        self.allow_capture = allow_capture

    async def list_sources(self) -> Dict[str, Any]:
        return {"sources": _jsonable(await self.client.sources())}

    async def get_source(self, selector: str = "", pid: Optional[int] = None) -> Dict[str, Any]:
        value = pid if pid is not None else selector
        if value == "":
            raise SonexisError("invalid_argument", "selector or pid is required")
        return {"source": _jsonable(await self.client.get_source(value))}

    async def get_diagnostics(self) -> Dict[str, Any]:
        return {"status": _jsonable(await self.client.status())}

    async def get_session(self, session_id: str) -> Dict[str, Any]:
        return {"session": _jsonable(await self.client.status(session_id))}

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
        return {
            "session": _jsonable(info),
            "audio_delivery": "Use Sonexis.attach_capture(session_id) over the binary data plane; MCP never carries PCM.",
        }

    async def stop_capture(self, session_id: str) -> Dict[str, Any]:
        self._require_capture_control()
        return {"session": _jsonable(await self.client.stop(session_id))}

    def _require_capture_control(self) -> None:
        if not self.allow_capture:
            raise SonexisError(
                "capture_control_disabled",
                "Start the MCP server with --allow-capture to enable capture mutation",
            )
