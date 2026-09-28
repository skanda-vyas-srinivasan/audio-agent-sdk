"""Exceptions raised by the Sonexis SDK."""

import re
from typing import Any, Dict, Optional


def sanitized_provider_error(error: BaseException) -> str:
    """Return bounded provider diagnostics with common credential forms removed."""
    text = str(error)[:2_000]
    text = re.sub(r"(?i)\b(bearer)\s+[^\s,;]+", r"\1 [REDACTED]", text)
    text = re.sub(
        r"(?i)\b(api[_-]?key|authorization|access[_-]?token|token|key)"
        r"(\s*[=:]\s*)[^\s&,;]+",
        r"\1\2[REDACTED]",
        text,
    )
    text = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "[REDACTED]", text)
    text = re.sub(r"\bAIza[A-Za-z0-9_-]{8,}\b", "[REDACTED]", text)
    return text


class SonexisError(Exception):
    """A structured Runtime or SDK error."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        retryable: bool = False,
        details: Optional[Dict[str, str]] = None,
        request_id: Optional[str] = None,
    ) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details or {}
        self.request_id = request_id

    @classmethod
    def from_response(cls, response: Dict[str, Any]) -> "SonexisError":
        error = response.get("error") or {}
        code = str(error.get("code", "runtime_error"))
        error_type = {
            "source_unavailable": SourceUnavailableError,
            "source_not_found": SourceNotFoundError,
            "unsupported_format": UnsupportedFormatError,
            "session_limit_exceeded": SessionLimitError,
            "permission_denied": PermissionDeniedError,
            "slow_consumer": SlowConsumerError,
            "capture_failed": CaptureFailedError,
            "capture_initialization_failed": CaptureFailedError,
            "microphone_capture_initialization_failed": CaptureFailedError,
            "microphone_conversion_failed": CaptureFailedError,
            "microphone_device_changed": CaptureFailedError,
            "unsupported_microphone_device": UnsupportedFormatError,
            "unsupported_microphone_format": UnsupportedFormatError,
            "output_unavailable": OutputUnavailableError,
            "output_destination_unavailable": OutputUnavailableError,
            "output_destination_disconnected": OutputUnavailableError,
            "output_device_unavailable": OutputUnavailableError,
            "output_session_limit_exceeded": SessionLimitError,
            "unsupported_output_format": UnsupportedFormatError,
            "unsupported_output_device_format": UnsupportedFormatError,
            "output_initialization_failed": OutputFailedError,
            "output_flush_failed": OutputFailedError,
            "output_stream_failed": OutputFailedError,
            "output_stream_truncated": OutputFailedError,
            "output_device_change_failed": OutputFailedError,
            "output_conversion_failed": OutputFailedError,
            "output_converter_unavailable": OutputFailedError,
            "output_buffer_allocation_failed": OutputFailedError,
            "output_ended_during_start": OutputFailedError,
            "output_not_writable": OutputFailedError,
        }.get(code, cls)
        return error_type(
            code,
            str(error.get("message", "Runtime request failed")),
            retryable=bool(error.get("retryable", False)),
            details={str(k): str(v) for k, v in (error.get("details") or {}).items()},
            request_id=response.get("request_id"),
        )


class SonexisConnectionError(SonexisError):
    """The local Runtime connection failed or closed."""


class SonexisProtocolError(SonexisError):
    """The Runtime sent malformed or incompatible protocol data."""


class SourceNotFoundError(SonexisError):
    """No currently available source matched a selector."""


class AmbiguousSourceError(SonexisError):
    """A selector matched more than one source and must be made explicit."""


class OutputDestinationNotFoundError(SonexisError):
    """No currently available output destination matched a selector."""


class AmbiguousOutputDestinationError(SonexisError):
    """An output selector matched more than one destination."""


class ProviderError(SonexisError):
    """An optional realtime provider adapter failed."""


class CaptureFailedError(SonexisError):
    """A capture reached terminal failure after it had started."""


class SourceUnavailableError(SonexisError):
    """A known source is not currently available; refreshing may succeed."""


class UnsupportedFormatError(SonexisError):
    """The Runtime or provider does not accept the requested audio format."""


class SessionLimitError(SonexisError):
    """The Runtime's bounded capture-session limit was reached."""


class PermissionDeniedError(SonexisError):
    """macOS denied the Runtime permission to capture application audio."""


class SlowConsumerError(SonexisError):
    """A consumer fell behind a bounded realtime stream."""


class OutputUnavailableError(SonexisError):
    """The requested Runtime-owned audio output destination is unavailable."""


class OutputFailedError(SonexisError):
    """An output session failed during setup, streaming, flush, or render."""
