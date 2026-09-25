# Sonexis Runtime v0.2 benchmarks

## Scope and methodology

These measurements cover deterministic portions of the Runtime that do not require Screen & System Audio Recording permission. They were collected on 2026-09-24 with:

- MacBook Pro `Mac16,1`, Apple M4 (10 cores), 16 GB RAM;
- macOS 27.0 build 26A428;
- Xcode 27.0 build 27A266a;
- optimized standalone Swift benchmark (`xcrun swiftc -O`).

Run the repeatable benchmark with:

```sh
Scripts/benchmark-runtime.sh
```

The conversion benchmark feeds 2,000 interleaved Float32 stereo blocks of 2,048 frames at 48 kHz—85.333 seconds of source audio—through the same stateful `RuntimeAudioNormalizer` used by capture sessions. It records wall time and output bytes. The framing benchmark encodes and decodes 100,000 PCM v2 packet headers with 320-byte payloads.

The lifecycle stress command is:

```sh
Scripts/test-runtime-stress.sh
```

It runs a real Runtime server over Unix sockets with a synthetic capture backend, performs 1,000 start/stop/idempotent-stop cycles, 200 complete control connection handshakes/disconnects, and 16 simultaneous sessions across four clients. It samples open descriptors before and after and reports peak RSS. This is a correctness/stability stress test, not a latency benchmark.

## Results

| Output format | Source audio | Wall time | Realtime factor | Output |
| --- | ---: | ---: | ---: | ---: |
| PCM16 16 kHz mono | 85.333 s | 0.010787 s | 7,910.6× | 2.731 MB |
| PCM16 24 kHz mono | 85.333 s | 0.012344 s | 6,912.7× | 4.096 MB |
| PCM16 48 kHz mono | 85.333 s | 0.006042 s | 14,122.8× | 8.192 MB |
| PCM16 48 kHz stereo | 85.333 s | 0.004288 s | 19,900.5× | 16.384 MB |
| Float32 48 kHz mono | 85.333 s | 0.005889 s | 14,491.1× | 16.384 MB |
| Float32 48 kHz stereo | 85.333 s | 0.004971 s | 17,165.7× | 32.768 MB |

PCM v2 framing completed 100,000 encode/header-decode iterations in 0.195959 seconds: approximately 510,311 packets/s and 196.0 MB/s including the 64-byte header.

The final lifecycle stress run completed in 0.840 seconds. It reported one additional descriptor while the test Runtime was still inside its deferred shutdown scope, 10,223,616 bytes peak RSS, and no active sessions after churn. The process baseline peak RSS was 6,356,992 bytes. Peak RSS is a high-water measurement and does not prove that every allocator returned pages to the OS; the bounded session history and descriptor assertion are the stronger invariants.

The integration slow-consumer test offered 500 maximum-size synthetic packets to a non-reading subscriber. It verified that the 64-packet application queue bound was never exceeded and that saturation caused accounted queue drops or subscriber disconnection rather than unbounded allocation.

## Interpretation

Format conversion and packet framing are comfortably faster than realtime on this host. These microbenchmarks intentionally exclude Core Audio Process Tap creation, scheduler wake-up behavior, kernel socket latency under normal 10 ms pacing, and downstream client processing. Debug builds, different hardware, thermal state, and macOS versions will change the results.

## Measurements still requiring signed manual validation

- Process Tap callback to Runtime frame latency using HAL host timestamps;
- application-to-client end-to-end p50/p95/p99 latency;
- Runtime CPU/RSS during sustained live one-, two-, and four-application capture;
- device-change gap duration and recovery latency;
- TCC permission-denied and permission-change behavior;
- practical Core Audio limits for independent same-source taps.

The current capture seam does not preserve HAL host time, so synthetic monotonic timestamps cannot honestly stand in for live input latency. That measurement belongs in signed acceptance testing rather than this offline report.
