#ifndef RealtimeAudioRing_h
#define RealtimeAudioRing_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

typedef struct SonexisAudioRingBuffer SonexisAudioRingBuffer;

SonexisAudioRingBuffer * _Nullable SonexisAudioRingBufferCreate(
    uint32_t capacityFrames,
    uint32_t channels
);
void SonexisAudioRingBufferDestroy(SonexisAudioRingBuffer *ringBuffer);

uint32_t SonexisAudioRingBufferWriteFromAudioBufferList(
    SonexisAudioRingBuffer *ringBuffer,
    const AudioBufferList *inputData
);

uint32_t SonexisAudioRingBufferWriteInterleaved(
    SonexisAudioRingBuffer *ringBuffer,
    const float *inputSamples,
    uint32_t frames
);

uint32_t SonexisAudioRingBufferReadToAudioBufferList(
    SonexisAudioRingBuffer *ringBuffer,
    AudioBufferList *outputData
);

uint32_t SonexisAudioRingBufferReadInterleaved(
    SonexisAudioRingBuffer *ringBuffer,
    float *outputSamples,
    uint32_t frames
);

/// C-only HAL output callback. `inClientData` must be a live
/// SonexisAudioRingBuffer pointer with the device's output channel count.
OSStatus SonexisAudioRingBufferIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void * _Nullable inClientData
);

/// C-only HAL input callback. `inClientData` must be a live
/// SonexisAudioRingBuffer pointer matching the input device channel count.
OSStatus SonexisAudioRingBufferInputIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void * _Nullable inClientData
);

/// Discards all currently readable frames. This control-thread-only operation
/// closes the read gate and waits for an in-flight realtime read before moving
/// the cursor. Audio already handed to Core Audio may still render for up to
/// one device callback period.
uint32_t SonexisAudioRingBufferFlush(SonexisAudioRingBuffer *ringBuffer);

void SonexisAudioRingBufferSetReadEnabled(SonexisAudioRingBuffer *ringBuffer, bool enabled);
/// Permanently closes the realtime read gate and waits for callbacks already
/// inside the ring to leave. Call only from a non-realtime control thread,
/// after unregistering the callback and before destroying the ring.
void SonexisAudioRingBufferQuiesceReads(SonexisAudioRingBuffer *ringBuffer);
void SonexisAudioRingBufferSetTargetFillFrames(SonexisAudioRingBuffer *ringBuffer, uint32_t targetFillFrames);
uint32_t SonexisAudioRingBufferGetFillFrames(SonexisAudioRingBuffer *ringBuffer);
uint32_t SonexisAudioRingBufferGetWritableFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetDroppedFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetUnderflowFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetWrittenFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetWriteOperations(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetReadFrames(SonexisAudioRingBuffer *ringBuffer);
uint64_t SonexisAudioRingBufferGetRenderedFrames(SonexisAudioRingBuffer *ringBuffer);
uint32_t SonexisAudioRingBufferGetLastInputPeakPPM(SonexisAudioRingBuffer *ringBuffer);
uint32_t SonexisAudioRingBufferGetTargetFillFrames(SonexisAudioRingBuffer *ringBuffer);
void SonexisAudioRingBufferSetGainImmediate(SonexisAudioRingBuffer *ringBuffer, float gain);
void SonexisAudioRingBufferRequestGainRamp(SonexisAudioRingBuffer *ringBuffer, float targetGain, uint32_t rampFrames);
uint32_t SonexisAudioRingBufferGetCurrentGainPPM(SonexisAudioRingBuffer *ringBuffer);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#endif
