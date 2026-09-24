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
        return cls(
            str(error.get("code", "runtime_error")),
            str(error.get("message", "Runtime request failed")),
            retryable=bool(error.get("retryable", False)),
            details={str(k): str(v) for k, v in (error.get("details") or {}).items()},
            request_id=response.get("request_id"),
        )


class SonexisConnectionError(SonexisError):
    """The local Runtime connection failed or closed."""


class SonexisProtocolError(SonexisError):
    """The Runtime sent malformed or incompatible protocol data."""
