# Sonexis Runtime benchmarks

## 1.0 release-candidate gate

The definitive automated 1.0 gate ran on 2026-09-27 against committed source
`43dc3433d6de780f97a924a30647eb802faf939c` on the Apple M4/macOS 27.0 host.
The audio data planes are unchanged from the v0.8 measurements below; this run
is release qualification rather than a new throughput claim.

The optimized stress executable completed 1,000 capture cycles, 1,000 output
cycles, 100 framed PCM burst cycles, 200 control connections, and 16 parallel
sessions in 1.525 seconds. Descriptor growth was two while deferred shutdown
resources remained in scope. Current RSS moved from 6,651,904 to 12,877,824
bytes (6,225,920 bytes retained), and peak RSS was 12,926,976 bytes.

The same workload under Thread Sanitizer completed in 4.083 seconds with two
in-scope descriptors. Current RSS moved from 53,641,216 to 94,846,976 bytes
(41,205,760 bytes retained), and peak RSS was 94,928,896 bytes. The concurrent
output-ring flush/read/write test and focused application lifecycle/graph tests
also passed under TSan.

These are deterministic lifecycle/resource bounds, not live HAL latency or an
hours-long physical-device soak. Live Process Tap, output-device, loopback, and
provider timing remain the explicit manual matrix in
`runtime-v1.0-manual-validation.md`.

## v0.8 reliability checkpoint

The v0.8 offline benchmark set was rerun on 2026-09-27 on the Apple M4/macOS
27.0 host used by earlier checkpoints. These commands do not open a Process Tap
or physical output device:

```sh
Scripts/benchmark-runtime.sh
Scripts/benchmark-runtime-v03.sh
Scripts/benchmark-runtime-v04.sh
Scripts/test-runtime-soak.sh
```

Capture normalization processed 85.333 seconds of 48 kHz stereo Float32 input
between 10,182.5× and 31,476.2× realtime across the six advertised formats.
Protocol-v2 frame encode/header-decode completed 100,000 iterations in
0.096615 seconds: 1,035,031 packets/s and 397.5 MB/s including the 64-byte
header.

| Output path | Represented audio | Wall time | Realtime factor |
| --- | ---: | ---: | ---: |
| PCM16 24 kHz mono → Float32 48 kHz stereo | 200 s | 0.026980 s | 7,412.9× |
| PCM16 48 kHz stereo → Float32 48 kHz stereo | 200 s | 0.008279 s | 24,157.4× |
| Float32 48 kHz mono → Float32 44.1 kHz stereo | 200 s | 0.025867 s | 7,731.8× |
| two-channel ring write/read | 200 s | 0.017781 s | 11,248.1× |

The deterministic provider/replay benchmark completed 4,000 frames in
484.999 ms (replay), 518.885 ms (OpenAI base64), and 517.232 ms (Gemini blob).
Its forced eight-frame slow-consumer queue stayed at a high-water mark of eight;
1,896 frames were consumed and all 2,104 discarded frames were accounted.
Peak process RSS was 25,182,208 bytes and Python `tracemalloc` peak was
1,300,045 bytes.

The new hours-equivalent lifecycle/PCM soak completed 10,000 capture cycles,
10,000 output cycles, 2,000 framed output-burst sessions, 2,000 control
connections, and 16 parallel sessions in 13.020 seconds. Descriptor growth was
two while the Runtime remained inside its deferred shutdown scope. Current RSS
grew from 6,635,520 to 12,468,224 bytes (5,799,936 bytes retained); active
sessions/subscribers/producers returned to zero and every queue remained within
its declared bound. This is deterministic high-churn evidence, not an 8-hour
wall-clock soak or live-HAL measurement.

v0.8 adds status/resource sampling off realtime threads only. It does not alter
capture normalization, playback conversion, either C ring, or PCM framing, and
the benchmark changes are normal host/run variance rather than an optimization
claim.

## v0.6 endpoint/routing validation

The v0.6 optimized converter/ring benchmark was rerun on 2026-09-27 on the
same Apple M4 host and macOS 27.0 build 26A428:

```sh
Scripts/benchmark-runtime-v04.sh
```

| Path | Represented audio | Wall time | Realtime factor | Device frames |
| --- | ---: | ---: | ---: | ---: |
| PCM16 24 kHz mono → Float32 48 kHz stereo | 200 s | 0.030395 s | 6,580.1× | 9,600,000 |
| PCM16 48 kHz stereo → Float32 48 kHz stereo | 200 s | 0.008726 s | 22,921.2× | 9,600,000 |
| Float32 48 kHz mono → Float32 44.1 kHz stereo | 200 s | 0.027140 s | 7,369.3× | 8,820,000 |
| two-channel ring write/read | 200 s | 0.017763 s | 11,259.1× | 9,600,000 |

This microbenchmark does not traverse a live HAL route, so it neither measures
the new 75 ms callback-coalescing window nor physical device-switch latency.
The v0.6 format matrix separately verifies exact 100 ms duration for all six
advertised ingress formats against 44.1, 48, and 96 kHz mono/stereo device
formats, plus packed/interleaved/planar ASBD bounds. It is a correctness test,
not a timing measurement.

The final non-TSan release-gate stress completed 1,000 capture cycles, 1,000
output cycles, 200 connections, and 16 parallel sessions in 1.390 seconds with
one descriptor of in-scope growth and 11,288,576 bytes peak RSS. The TSan run
completed in 3.950 seconds with the same descriptor bound and 88,358,912 bytes
peak RSS. The C output test now invokes the production IOProc shape against
both interleaved and planar `AudioBufferList` layouts while a producer and
flusher race under TSan.

## v0.4 output benchmark

The repeatable output benchmark was collected on 2026-09-26 on the Apple M4
host described below with optimized Swift/C code:

```sh
Scripts/benchmark-runtime-v04.sh
```

It feeds 10,000 20 ms packets (200 seconds of represented audio) through the
exact Runtime playback converter without opening a device, drains converter
tail, and separately cycles 20,000 10 ms stereo blocks through the C SPSC
ring. It excludes socket scheduling, HAL callback scheduling, and audible
device latency.

| Path | Represented audio | Wall time | Realtime factor | Device frames |
| --- | ---: | ---: | ---: | ---: |
| PCM16 24 kHz mono → Float32 48 kHz stereo | 200 s | 0.025717 s | 7,777.0× | 9,600,000 |
| PCM16 48 kHz stereo → Float32 48 kHz stereo | 200 s | 0.007713 s | 25,929.3× | 9,600,000 |
| Float32 48 kHz mono → Float32 44.1 kHz stereo | 200 s | 0.027031 s | 7,398.9× | 8,820,000 |
| two-channel ring write/read | 200 s | 0.017768 s | 11,256.1× | 9,600,000 |

The exact frame totals are part of the benchmark result. During live HAL
validation, a 0.5-second 24 kHz mono fixture produced exactly 22,050 device
frames on the current 44.1 kHz headphone output and exactly 24,000 frames on
the installed 48 kHz BlackHole loopback, with zero drops or overruns. Average
conversion time reported by those Debug sessions was 209.18 µs and 81.79 µs
per input packet respectively. These commands verified Runtime-to-HAL delivery;
they are not a listening or receiving-application latency measurement.

The v0.4 synthetic Runtime stress adds 1,000 output start/stop cycles to the
existing 1,000 capture cycles, 200 control connections, and 16 parallel capture
sessions. The final recorded values are reported in `RUNTIME_V0_4_REPORT.md`.
SDK tests additionally force a non-reading output socket, verify write
backpressure, and prove cancellation unblocks the producer.

Output latency is separated from provider latency. Runtime metrics expose
buffer target/depth, conversion work, device frames, underruns, overruns, and
drops; they do not claim model/network time. The default 60 ms target (or
configured 20–250 ms value) intentionally trades latency for burst tolerance.

## v0.3 AI pipeline benchmark

The v0.3 benchmark was collected on 2026-09-25 on the same Apple M4 host
described below, using the system Python 3.9.6. Run it with:

```sh
Scripts/benchmark-runtime-v03.sh
```

It sends 4,000 PCM16 mono chunks of 160 samples through deterministic replay
and injected provider transports. OpenAI uses 24 kHz input (26.667 seconds of
audio) and base64 encoding; Gemini and replay use 16 kHz (40 seconds). No
provider network, model processing, Core Audio, or Process Tap is involved.

| v0.3 path | Audio | Wall time | Raw throughput | Transport bytes |
| --- | ---: | ---: | ---: | ---: |
| replay frame generation | 40.000 s | 488.355 ms | 2.500 MiB/s | 1,280,000 |
| OpenAI adapter/base64 | 26.667 s | 543.414 ms | 2.246 MiB/s | 1,712,000 encoded |
| Gemini adapter/blob | 40.000 s | 582.016 ms | 2.097 MiB/s | 1,280,000 |

All three offline paths ran more than 45 times faster than their represented
audio duration. This is a transport/serialization microbenchmark, not a claim
about cloud response latency.

The bounded slow-consumer case offered 4,000 chunks to an eight-chunk queue
while deliberately delaying the consumer. The high-water mark stayed at eight;
2,326 chunks were consumed and 1,674 were accounted as dropped. Process peak
RSS was 22,544,384 bytes and Python `tracemalloc` peak was 1,300,045 bytes for
the complete benchmark. Peak RSS is a process high-water value, not retained
heap after cleanup.

The deterministic AI-consumer soak (`Scripts/test-runtime-v03.sh`) separately
uses two protocol-v2 streams, deliberate provider pauses, 30
cancel/reconnect cycles, task/descriptor/session assertions, and bounded queue
loss accounting. It is a correctness test rather than a throughput result.

## v0.2 Runtime baseline

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
