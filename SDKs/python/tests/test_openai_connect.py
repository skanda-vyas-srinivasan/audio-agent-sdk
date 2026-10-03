"""Exercise the adapter factory, including failures before a socket exists."""
import asyncio
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from sonexis.errors import ProviderError
from sonexis.providers import OpenAIRealtimeSink


@unittest.skipIf(sys.version_info < (3, 10), "OpenAI factory requires Python 3.10+")
class OpenAIConnectTests(unittest.IsolatedAsyncioTestCase):
    async def connect_with(self, client, **kwargs):
        with patch.dict(sys.modules, {"openai": SimpleNamespace(AsyncOpenAI=lambda **_: client)}):
            return await OpenAIRealtimeSink.connect(api_key="offline-placeholder", **kwargs)

    async def test_old_sdk_is_actionable_and_client_is_closed(self):
        client = SimpleNamespace(close=AsyncMock())  # openai 2.0 has no client.live.
        with self.assertRaises(ProviderError) as failure:
            await self.connect_with(client)
        self.assertEqual(failure.exception.code, "incompatible_dependency")
        self.assertIn("3.24", failure.exception.message)
        client.close.assert_awaited_once()

    async def test_context_factory_failure_closes_client(self):
        def broken_factory():
            raise RuntimeError("context creation failed")
        client = SimpleNamespace(live=SimpleNamespace(connect=broken_factory), close=AsyncMock())
        with self.assertRaises(ProviderError) as failure:
            await self.connect_with(client)
        self.assertEqual(failure.exception.code, "provider_handshake_failed")
        client.close.assert_awaited_once()

    async def test_cleanup_failure_does_not_mask_handshake_failure(self):
        context = SimpleNamespace(__aenter__=AsyncMock(side_effect=RuntimeError("enter failed")),
                                  __aexit__=AsyncMock(side_effect=RuntimeError("cleanup failed")))
        client = SimpleNamespace(live=SimpleNamespace(connect=lambda: context), close=AsyncMock())
        with self.assertRaises(ProviderError) as failure:
            await self.connect_with(client)
        self.assertEqual(failure.exception.code, "provider_handshake_failed")
        self.assertIn("enter failed", failure.exception.message)
        client.close.assert_awaited_once()

    async def test_stalled_cleanup_is_bounded_and_still_closes_client(self):
        async def blocked_exit(*_):
            await asyncio.Event().wait()
        context = SimpleNamespace(__aenter__=AsyncMock(side_effect=RuntimeError("enter failed")),
                                  __aexit__=blocked_exit)
        client = SimpleNamespace(live=SimpleNamespace(connect=lambda: context), close=AsyncMock())
        with self.assertRaises(ProviderError) as failure:
            await asyncio.wait_for(self.connect_with(client, close_timeout=0.01), timeout=0.5)
        self.assertIn("enter failed", failure.exception.message)
        client.close.assert_awaited_once()

    async def test_installed_sdk_connection_factory_contract_without_network(self):
        try:
            from openai import AsyncOpenAI
        except ImportError:
            self.skipTest("optional OpenAI extra not installed")
        client = AsyncOpenAI(api_key="offline-placeholder")
        try:
            # Use the real client's real manager factory. Block only network
            # entry, so incompatible dependency/API surfaces fail this test.
            manager_type = type(client.live.connect())
            with patch.object(manager_type, "__aenter__", AsyncMock(side_effect=RuntimeError("offline entry"))), \
                 patch.object(manager_type, "__aexit__", AsyncMock()) as exit_manager:
                with self.assertRaises(ProviderError) as failure:
                    await self.connect_with(client)
                self.assertEqual(failure.exception.code, "provider_handshake_failed")
                exit_manager.assert_awaited_once()
                self.assertTrue(client.is_closed())
        finally:
            await client.close()

    async def test_timeout_and_cancellation_close_context_and_client(self):
        for cancel in (False, True):
            entered = asyncio.Event()
            async def blocked_enter():
                entered.set()
                await asyncio.Event().wait()
            context = SimpleNamespace(__aenter__=blocked_enter, __aexit__=AsyncMock())
            client = SimpleNamespace(live=SimpleNamespace(connect=lambda: context), close=AsyncMock())
            task = asyncio.create_task(self.connect_with(client, handshake_timeout=0.02))
            await entered.wait()
            if cancel:
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
            else:
                with self.assertRaises(ProviderError):
                    await task
            context.__aexit__.assert_awaited_once()
            client.close.assert_awaited_once()

    async def test_successful_handshake_retains_events_and_owned_resources(self):
        async def events():
            yield SimpleNamespace(type="session.started")
            yield SimpleNamespace(type="response.created")
        class Connection:
            session = SimpleNamespace(start=AsyncMock(), close=AsyncMock())
            def __aiter__(self):
                return events()
        connection = Connection()
        context = SimpleNamespace(__aenter__=AsyncMock(return_value=connection), __aexit__=AsyncMock())
        client = SimpleNamespace(live=SimpleNamespace(connect=lambda: context), close=AsyncMock())
        sink = await self.connect_with(client)
        client.close.assert_not_awaited()
        connection.session.start.assert_awaited_once()
        iterator = sink.events()
        self.assertEqual((await iterator.__anext__()).type, "session.started")
        self.assertEqual((await iterator.__anext__()).type, "response.created")
        with self.assertRaises(StopAsyncIteration):
            await iterator.__anext__()
        await sink.aclose()
        context.__aexit__.assert_awaited_once()
        client.close.assert_awaited_once()
