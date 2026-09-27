"""Private Unix-socket trust checks shared by SDK transports."""

import asyncio
import os
import stat
from typing import Optional, Tuple

from .errors import SonexisConnectionError


def _trusted_socket(path: str) -> os.stat_result:
    directory = os.path.dirname(os.path.abspath(path))
    try:
        directory_status = os.lstat(directory)
        socket_status = os.lstat(path)
    except OSError as error:
        if error.errno == 2:
            raise SonexisConnectionError(
                "runtime_unavailable",
                f"Cannot connect to Sonexis Runtime at {path}. "
                "Start the local sonexis-runtime process or verify SONEXIS_RUNTIME_SOCKET.",
                retryable=True, details={"socket_path": path}) from error
        raise SonexisConnectionError(
            "untrusted_socket_path", "Sonexis socket path is unavailable or unsafe",
            retryable=True, details={"socket_path": path}) from error
    uid = os.getuid()
    if (not stat.S_ISDIR(directory_status.st_mode)
            or directory_status.st_uid != uid
            or stat.S_IMODE(directory_status.st_mode) & 0o022):
        raise SonexisConnectionError(
            "untrusted_socket_path",
            "Sonexis socket directory must be private and owned by the current user")
    if not stat.S_ISSOCK(socket_status.st_mode) or socket_status.st_uid != uid:
        raise SonexisConnectionError(
            "untrusted_socket_path",
            "Sonexis socket must be owned by the current user")
    return socket_status


async def open_trusted_unix_connection(
        path: str, *, limit: Optional[int] = None
) -> Tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    """Connect only through a stable socket node in a private user directory."""
    before = _trusted_socket(path)
    kwargs = {} if limit is None else {"limit": limit}
    reader, writer = await asyncio.open_unix_connection(path, **kwargs)
    try:
        after = _trusted_socket(path)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise SonexisConnectionError(
                "untrusted_socket_path", "Sonexis socket changed while connecting",
                retryable=True)
        return reader, writer
    except BaseException:
        writer.close()
        try:
            await writer.wait_closed()
        except (OSError, ConnectionError):
            pass
        raise
