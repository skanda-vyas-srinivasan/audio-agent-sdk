# External agent-framework integration

Sonexis stays below orchestration frameworks. Its useful boundary is one typed
async iterator of source-aware input frames and one bounded async output sink:

```python
async with Sonexis() as sx:
    async with await sx.capture("Discord", format=AudioFormat.speech_16k()) as source:
        async for frame in source:
            await pipeline_input.send(frame.data)
```

A LiveKit, Pipecat, or custom bridge should translate that framework's audio
frame type at this boundary. Retain a Runtime output for returned PCM and close
it deterministically:

```python
async with await sx.playback(format=response_format) as output:
    async for response in pipeline_output:
        await output.write(response.data)
```

Keep source labels in the task or pipeline context; do not anonymously mix
independent Sonexis captures. Use one provider or pipeline input per Sonexis
stream unless the framework explicitly models multiple labeled inputs.

The TypeScript mapping is the same: `CaptureStream` is an `AsyncIterable` of
typed frames, and `AudioOutput.write(Buffer)` accepts returned PCM. Own both in
one `try/finally`, then call `await output.close({drain: true})` and
`await capture.close()`.

The bridge owns four lifecycle rules:

1. negotiate one Sonexis format accepted by the downstream input;
2. propagate cancellation in both directions;
3. treat `frame.discontinuity` and drop counters as a reset boundary;
4. flush/cancel Sonexis output when application activity triggers barge-in.

Framework network transports, rooms, model workers, and authentication remain
outside Runtime. No LiveKit or Pipecat dependency is required to use Sonexis,
and adding either dependency to the Runtime would duplicate orchestration that
belongs above the audio I/O layer.
