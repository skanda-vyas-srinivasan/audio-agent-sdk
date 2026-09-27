"""Exceptions raised by the Sonexis SDK."""

from typing import Any, Dict, Optional


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
            "output_unavailable": OutputUnavailableError,
            "output_session_limit_exceeded": SessionLimitError,
            "unsupported_output_format": UnsupportedFormatError,
            "output_initialization_failed": OutputFailedError,
            "output_flush_failed": OutputFailedError,
            "output_stream_failed": OutputFailedError,
            "output_stream_truncated": OutputFailedError,
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
