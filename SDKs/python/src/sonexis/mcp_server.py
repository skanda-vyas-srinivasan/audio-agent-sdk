"""Optional stdio MCP server for the Sonexis Runtime control plane."""

import argparse
from contextlib import asynccontextmanager
import json
from typing import Any, Awaitable, Dict, Optional, TypeVar

from .client import Sonexis
from .errors import SonexisError
from .mcp_control import SonexisControlTools


T = TypeVar("T")


def _arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", help="Runtime control socket")
    parser.add_argument(
        "--allow-capture",
        action="store_true",
        help="advertise and enable capture start/inspect/stop tools (disabled by default)",
    )
    return parser.parse_args()


def build_server(socket_path: Optional[str], allow_capture: bool):
    try:
        from mcp.server import MCPServer
        from mcp.server.mcpserver.exceptions import ToolError
        from mcp.types import ToolAnnotations
    except ImportError as error:
        raise SystemExit("Install the Sonexis 'mcp' extra; MCP requires Python 3.10+") from error

    client = Sonexis(socket_path, client_name="sonexis-mcp", client_version="0.8.0")
    tools = SonexisControlTools(client, allow_capture=allow_capture)

    @asynccontextmanager
    async def lifespan(_server):
        try:
            yield {"client": client}
        finally:
            await client.close()

    server = MCPServer(
        name="sonexis-runtime",
        title="Sonexis Runtime Control",
        description="Local control plane for source-aware audio sessions.",
        instructions=("Control metadata and session lifecycle only. MCP never carries PCM; "
                      "use a Sonexis SDK for realtime audio."),
        version="0.8.0",
        lifespan=lifespan,
    )

    read_annotations = ToolAnnotations(
        readOnlyHint=True, destructiveHint=False,
        idempotentHint=True, openWorldHint=False)
    start_annotations = ToolAnnotations(
        readOnlyHint=False, destructiveHint=False,
        idempotentHint=False, openWorldHint=False)
    stop_annotations = ToolAnnotations(
        readOnlyHint=False, destructiveHint=True,
        idempotentHint=True, openWorldHint=False)

    async def ensure_connected() -> None:
        if client.handshake is None:
            await client.connect()

    async def invoke(call: Awaitable[T]) -> T:
        try:
            return await call
        except SonexisError as error:
            payload = {
                "code": error.code[:128],
                "message": error.message[:1_000],
                "retryable": error.retryable,
                "details": {str(key)[:128]: str(value)[:512]
                            for key, value in list(error.details.items())[:16]},
            }
            raise ToolError(json.dumps(payload, separators=(",", ":"))) from error

    @server.tool(annotations=read_annotations, structured_output=True)
    async def sonexis_runtime_info() -> Dict[str, Any]:
        """Describe protocol compatibility, limits, and the MCP control policy."""
        await invoke(ensure_connected())
        return await invoke(tools.runtime_info())

    @server.tool(annotations=read_annotations, structured_output=True)
    async def sonexis_list_sources() -> Dict[str, Any]:
        """List local application audio sources. Returns metadata, never audio."""
        await invoke(ensure_connected())
        return await invoke(tools.list_sources())

    @server.tool(annotations=read_annotations, structured_output=True)
    async def sonexis_get_source(selector: str = "", pid: Optional[int] = None) -> Dict[str, Any]:
        """Resolve exactly one source by ID, bundle ID, application name, or PID."""
        await invoke(ensure_connected())
        return await invoke(tools.get_source(selector, pid))

    @server.tool(annotations=read_annotations, structured_output=True)
    async def sonexis_get_diagnostics() -> Dict[str, Any]:
        """Return Runtime health and aggregate counters."""
        await invoke(ensure_connected())
        return await invoke(tools.get_diagnostics())

    @server.tool(annotations=read_annotations, structured_output=True)
    async def sonexis_list_output_destinations() -> Dict[str, Any]:
        """List output metadata. Realtime output audio remains on the SDK data plane."""
        await invoke(ensure_connected())
        return await invoke(tools.list_output_destinations())

    if allow_capture:
        @server.tool(annotations=read_annotations, structured_output=True)
        async def sonexis_list_sessions() -> Dict[str, Any]:
            """List captures owned by this MCP server process."""
            await invoke(ensure_connected())
            return await invoke(tools.list_sessions())

        @server.tool(annotations=read_annotations, structured_output=True)
        async def sonexis_get_session(session_id: str) -> Dict[str, Any]:
            """Return one capture owned by this MCP process and its metrics."""
            await invoke(ensure_connected())
            return await invoke(tools.get_session(session_id))

        @server.tool(annotations=start_annotations, structured_output=True)
        async def sonexis_start_capture(
            source: str, format_profile: str = "speech_16k"
        ) -> Dict[str, Any]:
            """Start capture; consume its PCM using the SDK binary data plane."""
            await invoke(ensure_connected())
            return await invoke(tools.start_capture(source, format_profile))

        @server.tool(annotations=stop_annotations, structured_output=True)
        async def sonexis_stop_capture(session_id: str) -> Dict[str, Any]:
            """Stop a capture owned by this MCP server process."""
            await invoke(ensure_connected())
            return await invoke(tools.stop_capture(session_id))

    return server


def main() -> None:
    args = _arguments()
    server = build_server(args.socket, args.allow_capture)
    server.run()


if __name__ == "__main__":
    main()
