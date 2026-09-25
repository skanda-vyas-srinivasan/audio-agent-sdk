"""Optional stdio MCP server for the Sonexis Runtime control plane."""

import argparse
from typing import Optional

from .client import Sonexis
from .mcp_control import SonexisControlTools


def _arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", help="Runtime control socket")
    parser.add_argument(
        "--allow-capture",
        action="store_true",
        help="enable start_capture; disabled by default because application audio is sensitive",
    )
    return parser.parse_args()


def build_server(socket_path: Optional[str], allow_capture: bool):
    try:
        from mcp.server import MCPServer
    except ImportError as error:
        raise SystemExit("Install the Sonexis 'mcp' extra; MCP requires Python 3.10+") from error

    server = MCPServer("Sonexis Runtime")
    client = Sonexis(socket_path, client_name="sonexis-mcp", client_version="0.3.0")
    tools = SonexisControlTools(client, allow_capture=allow_capture)

    async def ensure_connected() -> None:
        if client.handshake is None:
            await client.connect()

    @server.tool()
    async def sonexis_list_sources() -> dict:
        """List local application audio sources. Returns metadata, never audio."""
        await ensure_connected()
        return await tools.list_sources()

    @server.tool()
    async def sonexis_get_source(selector: str = "", pid: Optional[int] = None) -> dict:
        """Resolve exactly one source by ID, bundle ID, application name, or PID."""
        await ensure_connected()
        return await tools.get_source(selector, pid)

    @server.tool()
    async def sonexis_get_diagnostics() -> dict:
        """Return Runtime health and aggregate counters."""
        await ensure_connected()
        return await tools.get_diagnostics()

    @server.tool()
    async def sonexis_get_session(session_id: str) -> dict:
        """Return one capture session and its drop/throughput metrics."""
        await ensure_connected()
        return await tools.get_session(session_id)

    @server.tool()
    async def sonexis_start_capture(source: str, format_profile: str = "speech_16k") -> dict:
        """Start capture when explicitly enabled; consume its PCM with the SDK data plane."""
        await ensure_connected()
        return await tools.start_capture(source, format_profile)

    @server.tool()
    async def sonexis_stop_capture(session_id: str) -> dict:
        """Stop a Runtime capture session."""
        await ensure_connected()
        return await tools.stop_capture(session_id)

    return server


def main() -> None:
    args = _arguments()
    server = build_server(args.socket, args.allow_capture)
    server.run()


if __name__ == "__main__":
    main()
