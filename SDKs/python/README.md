# Sonexis Python SDK

The SDK connects to a local Sonexis Runtime v0.2 over Unix-domain sockets. It has no runtime dependencies.

```sh
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install -e SDKs/python
```

```python
from sonexis import Sonexis

async with Sonexis() as sx:
    sources = await sx.sources()
    async with await sx.capture(sources[0]) as stream:
        async for frame in stream:
            print(frame.sequence, frame.timestamp_ns, len(frame.data))
```

Capture sessions are not silently resumed after a reconnect. A Runtime control disconnect owns and terminates its sessions, so applications must explicitly start new captures.
