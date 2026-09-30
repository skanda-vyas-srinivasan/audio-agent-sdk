# AudioPlane holistic assessment

Reviewed on September 30, 2026, at commit `9ec212c`.

## Engineering follow-up — September 30, 2026

The original assessment below is retained as a historical review. All six reproduced correctness issues are now resolved in the working tree, with targeted regression coverage. The fixes preserve protocol v2 and the existing public capture/output APIs. Additional lifecycle defects and packaging inconsistencies were addressed during execution-path review.

### Working model

- The native Runtime owns permissions, Core Audio resources, source/destination discovery, and sessions associated with each control connection. Disconnecting that owner reconciles ambiguous resource-creation results.
- Application taps and physical-microphone capture hand preallocated PCM through the C realtime ring to serialized, non-realtime conversion workers. Application capture adds a bounded delivery queue. `RuntimeDataPlane` then frames and distributes PCM on a separate bounded socket queue; no new work was added to realtime callbacks.
- Playback validates client packets, converts on the ingest path, and supplies a bounded device-rate ring to HAL callbacks. Output stream UUIDs rotate on flush; session identity remains stable. Callback, ingest, and lifecycle ownership must stay separate.
- Python and TypeScript own async control requests, socket attachments, single-consumer iterators, serialized output writes, and composition helpers. Connection generations prevent an attachment from publishing after shutdown or reconnect. Label reservations now cover removal as well as creation.
- Provider adapters sit above the public SDK. Response playback owns its queue and response epoch. Idle interruption rotates the output through flush; interruption of an active write cancels that uncertain stream and recreates output when new response audio arrives.
- SwiftPM builds the Runtime, CLI, and repository-owned capture engine. Shell gates compile deterministic native harnesses, run sanitizers, exercise both SDKs, validate wheel/sdist/npm artifacts in clean consumers, and verify signed builds and a temporary installation. Live HAL/provider acceptance remains separate.

### Additional completed work

- **Resolved P1 — Python graceful close truncates an active write.** A user reproduced a 9,600-frame write transmitting only 4,800 frames and raising `output_closed` while graceful close succeeded. A paused first-packet regression reproduced this before the fix. `_closed` now rejects new operations and operations waiting for the write lock; the active write checks the separate cancellation event between packets. Explicit cancellation and drain-deadline expiry set that event and abort the transport without waiting for the lock. Regression tests verify all 9,600 frames, contiguous sequence/timestamps and EOS on graceful completion, rejected waiting/new writes, immediate cancellation escalation, and deadline expiry while an active write holds the lock. TypeScript already had the correct active-write behavior; a matching regression now protects its contract.
- **Resolved P2 — TypeScript microphone shutdown deadlock.** `MicrophonePassthrough.finishClose()` joined its forwarding pump before closing output. A stalled `write()` therefore prevented shutdown from ever reaching the action that would unblock it. Input/output now close before the pump is joined; intentional output-close errors are distinguished from forwarding failures. A deterministic regression failed on the old ordering and now passes.
- **Resolved P2 — Python microphone startup after shutdown.** `__aenter__()` could resume after `aclose()` completed and recreate an open passthrough. Opening and closing now share the lifecycle lock used by the duplex abstraction. A paused capture-attachment regression confirms completed teardown cannot be reversed by startup.
- **Resolved P2 — Unbounded Python control requests.** `request_timeout` defaults to 10 seconds and covers the write lock, socket backpressure, and response wait. Invalid deadlines are rejected. Read-only timeouts ignore late responses without poisoning the connection; ambiguous mutating timeouts abort the owner connection and reconcile wrappers. Tests cover both policies. Disconnects also invalidate generations and clean tracked resources before reconnect.
- **Resolved P2 — Late flush attachment after cancellation.** Both SDKs reject and dispose of a fresh stream socket if output closed while rotation was in flight. Cancellation bypasses the write-operation lock. New tests pause the flush response, cancel output, and verify the late socket is not retained.
- **Resolved P2 — Buffered Python transport survives cancellation.** `StreamWriter.close()` can keep a backpressured socket alive while flushing pending bytes. Cancellation and drain expiry now abort that transport. A real Unix-socket regression forces transport backpressure and verifies cancellation releases the socket and clears buffered bytes. Control teardown also aborts on timeout or ambiguous mutation.
- **Resolved P2 — Discovery wait overruns and delayed cancellation.** Positive source/destination wait deadlines in both SDKs now cover active snapshot lookups. TypeScript abort signals release the wait during a lookup. Zero timeout retains the existing one-snapshot behavior under the normal request deadline; tests and SDK documentation make that contract explicit. Python cancels the pending read-only lookup and safely discards its late response.
- **Resolved packaging inconsistency.** The legacy `setup.py` now includes the same WebRTC VAD dependency as `pyproject.toml` for `gemini` and `ai`. The package gate checks the installed wheel's parsed dependency markers. TypeScript repository, issue, and homepage links now target this standalone repository.

### Validation

- Full `Scripts/test-runtime-release.sh` gate: passed. Final discovery-wait changes were additionally verified by both SDK suites and the clean package/consumer gate. The later active-write graceful-close fix was verified by both SDK suites and the agent torture gate; native code was unchanged in that follow-up. Coverage includes native build, four engine tests, protocol/core/output/integration/fuzz tests, lifecycle stress, output-ring concurrency, Thread Sanitizer, examples, Python wheel/sdist installation, TypeScript tarball and external consumer typecheck, signed universal products, virtual-driver contract/ring/TSan checks, and temporary installer lifecycle/tamper-preservation tests.
- Python system 3.9: 157 tests after the active-write graceful-close follow-up; two optional native-VAD tests are skipped in that interpreter. Python 3.14 with the development environment: the suite also passes; the real-speech fixture is supplied separately.
- `Scripts/test-gemini-speech-vad.sh`: all 14 tests passed with synthesized offline speech and the native classifier.
- TypeScript: all 39 tests passed, including late capture/output/event attachment after reconnect, packet-tail preservation, stalled EOS/status cleanup, label replacement, flush cancellation, microphone shutdown, active discovery deadline/abort handling, and graceful completion of an active multi-packet write.
- Agent torture: 1,009,497 transitions, 1,000 turns, and 1,000 interruptions passed. The harness now explicitly forces both idle flush and active-write cancellation/recreation and rejects reuse of a cancelled mock output.
- The original native reproduction was rerun against the pre-fix data-plane source: it still marks sequence 0 for a later loss and rejects sequence 65 with `unmarked_pcm_gap`. The checked-in regression passes through the production decoder with the corrected ordering and preserves upstream loss metadata on a rejected packet.

The automated results do not establish audible barge-in latency, live application/microphone capture, authenticated provider conversations, or clean-machine notarized installation. Those remain the manual acceptance matrix.

### Remaining engineering work

- Consolidate the nine duplicated Swift IPC files into shared protocol/transport targets. The modified data-plane copies remain identical; a target extraction would also require coordinated build/test source-list changes.
- Make wire-model validation consistently strict, especially Python coercion and remaining TypeScript casts, using malformed-message regressions before changing accepted inputs.
- Add macOS CI for offline gates and consider splitting the large TypeScript client and Python agent along existing ownership boundaries. Avoid mixing broad module moves into lifecycle fixes.
- Complete the live acceptance matrix recorded in `AGENT_PRERELEASE_REPORT.md`, including microphone/Gemini retesting, audible interruption, device changes, and long sessions. Signed development builds and offline gates do not replace this.
- Resolve distribution, licensing, and release-positioning decisions from the original assessment, including the `Production/Stable` classifier. No license, package publication, or release action was performed here.

## Overall assessment

AudioPlane solves a real problem and is worth continuing. It has a sensible technical foundation, but I would treat it as a developer preview today. Its strongest opportunity is programmable desktop audio I/O for application developers. The biggest obstacles are installation friction, several reproducible lifecycle bugs, and proving that developers repeatedly use it in real applications.

The review covered the native Runtime, capture engine, playback implementation, virtual driver, Python and TypeScript clients, provider adapters, tests, and release documentation. It also included research into competing approaches and the checks described below. Repository source was not changed during the review.

## Idea, market gap, differentiation, and value

The market gap is real, but application capture itself is already available.

The valuable problem is: “Give my application reliable, labeled audio from desktop applications and let it send audio back, without making me implement Core Audio and maintain its lifecycle.”

That saves developers substantial integration work. However, the underlying capture capability is accessible through Apple’s APIs and existing open-source tools. AudioPlane’s differentiation needs to come from the complete developer experience.

| Existing approach | What it already provides | AudioPlane’s potential advantage |
|---|---|---|
| Apple Core Audio taps | Capture from a process or group of processes | Discovery, language clients, normalization, lifecycle management, diagnostics. [Apple documentation](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) |
| AudioTee / AudioTee.js | Process-selected PCM capture and a Node wrapper | Multiple labeled streams, persistent Runtime ownership, playback, events, and richer failure handling. [AudioTee](https://github.com/makeusabrew/audiotee), [Node wrapper](https://github.com/makeusabrew/audioteejs) |
| Loopback / BlackHole | Audio routing and virtual-device workflows | A programming interface that manages streams and formats for developers. [Loopback](https://rogueamoeba.com/loopback/), [BlackHole](https://github.com/ExistentialAudio/BlackHole) |
| Recall.ai Desktop SDK | Meeting recording, with platform-specific recording and raw-media capabilities | General application audio and local processing could appeal to developers who need a smaller infrastructure layer. [Recall documentation](https://docs.recall.ai/docs/desktop-sdk) |
| Pipecat / LiveKit | Agent pipelines and audio I/O | AudioPlane can supply desktop application audio underneath those frameworks. [Pipecat’s local transport](https://github.com/pipecat-ai/pipecat/blob/main/src/pipecat/transports/local/audio.py), [LiveKit audio I/O](https://docs.livekit.io/agents/server/startup-modes/) |

The distinctive combination is useful: application identity, independent streams, bidirectional PCM, multiple language clients, bounded transport, diagnostics, and a virtual microphone.

The individual features are reproducible by competitors. A stronger long-term advantage would be reliable operation across macOS releases, excellent installation, proven integrations, and developers trusting the SDK during device changes and long sessions.

## Utility and credible use cases

| Use case | Assessment |
|---|---|
| Local transcription, captions, and meeting assistants | Strong initial fit. Capture a meeting application and the microphone separately, then feed local or cloud speech recognition. |
| Desktop audio transport for Pipecat or LiveKit | Strong developer niche. A working framework adapter would make the SDK’s value immediately understandable. |
| Translation or generated speech injected into calls | Compelling demonstration, but interruption, feedback prevention, routing, and audible quality must be dependable. |
| Audio application testing and agent debugging | Strong technical fit. Replay, labeled sources, counters, and explicit lifecycle errors are useful here. |
| Music analysis and research | Useful, although many projects need only a simpler capture tool. |
| General microphone-based voice assistants | Less differentiated; developers have many existing microphone and playback options. |

Two distinctions matter when describing these use cases:

- An application label is not a speaker label. Capturing Discord does not identify each participant.
- Application capture is not browser-tab isolation. A Chrome source does not give developers semantic separation between meetings, videos, and other tabs.

Likewise, the SDK explicitly does not promise sample-accurate synchronization across applications. That limits multitrack recording and precise microphone/system-audio alignment.

These are plausible demand hypotheses. The repository does not establish adoption or willingness to pay. Validate those through external developers building actual applications.

## Architecture strengths

The native Runtime owning audio permissions and device resources is sensible. Separating JSON control traffic from binary PCM is appropriate. Keeping conversion and socket work away from audio callbacks is essential, and the bounded buffers, structured errors, stream epochs, and cancellation reconciliation show deliberate engineering.

Provider adapters sit above the audio layer, which is the right dependency direction. The source selector’s ambiguity handling is also good: silently capturing the wrong application would undermine the product.

The tests cover substantially more than basic happy paths. However, bounded memory and race-free access do not guarantee correct lifecycle ordering. That is where the most consequential problems appeared.

## Reproduced correctness issues

P1 means an issue should be fixed before recommending a release. P2 means a significant functional issue. These findings were reproduced in controlled tests; matching TypeScript behavior is identified separately where it was established by inspection.

### 1. Resolved — P1 — Capture queue drops can terminate a stream that should recover

**Resolution:** Queue-admission loss is captured when the next packet is accepted, before submission to the delivery worker. Loss discovered during delivery has its own queue-owned counter. The deterministic regression fills all 64 slots, drops sequence 64, and verifies that sequence 65 carries the gap and accumulated upstream loss. Runtime and CLI copies are synchronized.

Location: [RuntimeDataPlane.swift](Sources/SonexisRuntime/IPC/RuntimeDataPlane.swift), line 65.

A rejected packet updates a shared pending-drop counter. An earlier packet already waiting in the queue can consume that counter.

In a deterministic test, the delivery worker was paused to force a backlog: sequences `0–63` were queued, `64` was dropped, then `65` was delivered. Sequence `0` received the discontinuity marker. Sequence `65` had none, so the production decoder rejected it with `unmarked_pcm_gap`.

**Impact:** temporary delivery congestion can kill capture instead of producing an observable gap.

**Fix:** associate losses with their position in stream order. Attach the discontinuity to the first accepted packet after the loss, rather than whichever queued packet executes next.

### 2. Resolved — P1 — Immediate cancellation cannot override a graceful close already in progress

**Resolution:** Python uses an independently signaled cancellation path; TypeScript uses an abort controller. Either can override graceful close, and the three-second drain deadline includes operation-lock waits, EOS transport backpressure, and status requests. Cancellation/timeout aborts the data transport. Tests cover stalled EOS, stalled status, and real socket backpressure.

Locations: [Python output.py](SDKs/python/src/sonexis/output.py), line 177; [TypeScript index.ts](SDKs/typescript/src/index.ts), line 1394.

The first close creates a cleanup task or promise. Subsequent `cancel()` calls join it, even if it is draining.

The reproduction blocked the graceful close in transport `drain()`, then called `cancel()`. Cancellation remained pending and did not close the transport. The later three-second playback deadline does not bound this earlier transport wait.

**Impact:** shutdown can hang when the consumer stalls. Client shutdown can also inherit the stalled cleanup.

**Fix:** allow cancellation to escalate an existing graceful close. Retain a way to abort the transport throughout cleanup, and bound the complete drain operation. This was reproduced in Python; TypeScript contains the same first-close-wins structure.

### 3. Resolved — P2 — Valid large output writes can generate invalid packets

**Resolution:** Python and TypeScript redistribute a short tail into the preceding packet so every non-EOS packet satisfies the 1–200 ms contract. Regression tests verify byte-for-byte PCM preservation, valid frame counts, and timestamp continuity.

Locations: [Python output.py](SDKs/python/src/sonexis/output.py), line 99; [RuntimeOutputDataPlane.swift](Sources/SonexisRuntime/IPC/RuntimeOutputDataPlane.swift), line 163.

At 24 kHz, writing `4,801` samples produces packets of `4,800` and `1` sample. The Runtime requires each packet to contain at least `24` samples.

The SDK’s split and the native receiver’s `output_packet_too_short` rejection were confirmed. TypeScript uses the same splitting strategy.

**Impact:** ordinary arbitrary-length PCM writes can fail despite satisfying the public write requirement.

**Fix:** redistribute the final two packets so both satisfy the minimum, preserving PCM exactly.

### 4. Resolved — P2 — Capture attachment can finish after client shutdown

**Resolution:** Both SDKs capture the connection generation before resource creation and validate it before publishing an attached wrapper. Stale captures, outputs, and subscriptions are disposed rather than registered. Reconnect regressions confirm the new connection remains usable.

Location: [client.py](SDKs/python/src/sonexis/client.py), lines 165 and 385.

Client shutdown snapshots the tracked captures. Capture creation registers its wrapper only after awaiting the data-socket attachment.

With attachment deliberately paused, the reproduction closed the client, resumed attachment, and received an open wrapper registered on a disconnected client.

**Impact:** callers can receive resources outside the completed teardown snapshot. The native owner cleanup normally stops the underlying capture, so this is not proof of permanently leaked native capture.

**Fix:** track in-flight resource creation and use a connection-generation or closing-state check before publishing the wrapper. Apply the same invariant to output and event attachment.

### 5. Resolved — P2 — Response interruption waits behind a stalled output write

**Resolution:** The response player tracks its active write independently. Interruption cancels that task and immediately closes the old output without waiting behind its operation lock; subsequent response audio creates a fresh output. Idle output still uses flush. Regression and torture coverage exercise both paths.

Location: [agent.py](SDKs/python/src/audioplane/agent.py), lines 638 and 712.

`interrupt_response()` changes the epoch and queues a flush command. The worker executing that command can already be blocked in `output.write()`.

The reproduction showed an interruption returning while the output remained unflushed. It flushed only after the blocked write resumed. Direct SDK `flush()` also waits behind the write-operation lock.

**Impact:** barge-in responsiveness depends on the old write completing.

**Fix:** give interruption an independently controlled abort path. Account for the current rule that cancelling a Python write closes its output session; session reuse or recreation must be explicit.

### 6. Resolved — P2 — Concurrent removal and replacement of a label deletes the replacement’s queue

**Resolution:** Both SDKs reserve a label until its old capture, pump, and queue state finish removal. Python shields the removal task so caller cancellation cannot release the reservation early. Replacement regressions verify the new queue remains usable.

Locations: [Python multi.py](SDKs/python/src/sonexis/multi.py), line 127; [TypeScript index.ts](SDKs/typescript/src/index.ts), line 2316.

Removal deletes the capture entry, awaits cleanup, then deletes queue state by label. During that await, another task can add a new capture under the same label.

The reproduction left a replacement capture registered while its queue had been deleted.

**Impact:** concurrent source switching can silently stop delivering frames.

**Fix:** reserve the label until removal completes, or store each member’s state in a generation-specific object. This was reproduced in Python; TypeScript has the equivalent ordering.

### Reproduction evidence

The review created temporary harnesses at the following local paths. They are outside this repository and may not survive temporary-directory cleanup:

- `/private/tmp/audioplane-review/repros.py`
- `/private/tmp/audioplane-review/main.swift`

Observed results included:

```text
packet_tail: [4800, 1] native minimum=24 frames
late_capture: returned_closed=False tracked_after_close=1 control_connected=False
blocked_barge_in: interruption_returned=True output_flushed=False
remove_add_race: replacement_tracked=True replacement_queue_exists=False
cancel_during_drain_close: cancel_done=False transport_closed=False
capture_drop: discontinuity on sequence=0, dropped=160
capture_drop: decoder rejected sequence=65, flags=0, error=unmarked_pcm_gap
native_tail: output_packet_too_short
```

## Code organization and engineering practices

Code organization needs consolidation more than a broad rewrite.

The clearest problem is nine identical Swift IPC files duplicated between the Runtime and CLI, totaling roughly 4,500 duplicated lines. They match today, but every protocol change creates an opportunity for drift.

Introduce shared Swift targets:

- `RuntimeProtocol`: wire models, framing, and codecs.
- `RuntimeIPC`: socket transport and client implementation.
- Runtime-only server and coordinator code.
- Thin executable targets for startup and CLI behavior.

That would also reduce the manually maintained source lists in the shell test scripts.

The TypeScript client’s single 2,684-line file combines models, parsing, transport, capture, output, activity detection, and orchestration. Split it along those existing responsibilities while retaining a single public export surface.

Similarly, the Python 1,276-line agent module mixes CLI behavior, validation reporting, provider-input queues, playback, and orchestration. Smaller modules would make lifecycle changes easier to reason about.

Other worthwhile improvements:

- Give each concurrent resource one explicit state machine and ownership object. Parallel dictionaries and scattered booleans make replacement races easier.
- **Completed:** configurable Python control-request deadlines and in-flight source/destination wait deadlines, as recorded in the follow-up.
- Document single-reader/single-writer assumptions and queue ownership beside the implementation.
- Use stricter wire validation consistently. Several Python model parsers coerce malformed values rather than rejecting them; parts of TypeScript trust casts.
- **Completed:** WebRTC VAD extras now agree between `setup.py` and `pyproject.toml`; further packaging-metadata consolidation remains useful.
- Add macOS CI for the offline gates; this checkout has no `.github` workflow directory.
- **Completed:** TypeScript package links now point to the standalone AudioPlane repository.

Preserve the overall audio/control separation during this work.

## Distribution, licensing, and release positioning

Distribution is currently the largest adoption obstacle.

The quickstart requires native compilation, a signing identity, a separately started Runtime, and then SDK installation. Virtual microphone installation adds a system-level step and reboot.

For a developer evaluating a dependency, that is substantial friction before receiving the first useful frame.

The next product milestone should make these steps predictable:

1. Install a signed, notarized Runtime.
2. Explain and verify permissions.
3. Capture a chosen application.
4. Run a complete integration example.
5. Recover from device changes and Runtime restarts.
6. Uninstall cleanly.

Licensing also deserves a deliberate product decision. Both client SDKs are GPL-licensed, which creates an adoption question for proprietary application teams. Clarify supported commercial integration arrangements; permissively licensed clients could be worth considering if ownership permits. GPL library integration and separate-process communication have different considerations in the [GNU licensing guidance](https://www.gnu.org/licenses/gpl-faq.en.html).

The `Production/Stable` package classifier is stronger than the evidence supports. The release documentation explicitly records outstanding live acceptance, including the post-fix microphone/Gemini retest. Align the metadata and public positioning with that status.

## Validation performed and limits

The following checks ran and passed:

- Native build and four engine package tests.
- Runtime protocol, normalization, output-core, integration, and fuzz tests.
- Runtime lifecycle stress and concurrent output-ring tests under Thread Sanitizer.
- Virtual-driver contract, ring, and ring Thread Sanitizer tests.
- 137 Python tests; optional speech coverage depended on the interpreter environment.
- The separate native speech fixture suite: all 14 tests passed.
- All 29 TypeScript tests.
- The agent torture gate: 1,009,497 transitions, 1,000 turns, and 1,000 interruptions.
- Version-consistency and repository-independence checks.

The review did not validate live meeting capture, audible physical playback, authenticated provider conversations, or clean-machine installation. The OpenAI adapter was checked against official OpenAI documentation, but its authenticated network path was not executed.

The newly reproduced failures explain why test volume alone is insufficient: the missing coverage concerns specific event orderings and SDK-to-Runtime contracts. Those should become focused regressions. Longer live tests should then measure audible interruption, recovery, and end-to-end latency—not just synthetic throughput.

## Recommended priorities

The six reproduced issues are resolved as recorded above. Continue with the remaining wire-validation work, simplify duplicated code, then prove one external integration and the installation experience.

Initially target developers building local transcription or meeting tools, and developers who need application audio inside an existing agent framework. Recruit a few external builders and measure whether they can install it unaided, reach their first useful stream quickly, and keep using it after their first project session.

AudioPlane has enough functionality to pursue that validation. Further features will be less valuable until the existing capture, playback, interruption, and installation paths are dependable.
