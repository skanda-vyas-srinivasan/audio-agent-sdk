#ifndef AUDIOPLANE_RING_BUFFER_H
#define AUDIOPLANE_RING_BUFFER_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#if ATOMIC_LLONG_LOCK_FREE != 2
#error "AudioPlane Input requires lock-free 64-bit atomics"
#endif

typedef struct AudioPlaneRingBuffer {
    float *samples;
    uint32_t capacityFrames;
    uint32_t channels;
    _Atomic uint64_t readFrame;
    _Atomic uint64_t writeFrame;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t underrunFrames;
    _Atomic bool readPrimed;
} AudioPlaneRingBuffer;

bool AudioPlaneRingBufferInitialize(AudioPlaneRingBuffer *ring, float *storage,
                                    uint32_t capacityFrames, uint32_t channels);
void AudioPlaneRingBufferReset(AudioPlaneRingBuffer *ring);
uint32_t AudioPlaneRingBufferWrite(AudioPlaneRingBuffer *ring, const float *source,
                                   uint32_t frameCount);
uint32_t AudioPlaneRingBufferRead(AudioPlaneRingBuffer *ring, float *destination,
                                  uint32_t frameCount);
uint32_t AudioPlaneRingBufferReadPrimed(AudioPlaneRingBuffer *ring, float *destination,
                                        uint32_t frameCount, uint32_t primeFrameCount);
uint32_t AudioPlaneRingBufferQueuedFrames(const AudioPlaneRingBuffer *ring);
uint64_t AudioPlaneRingBufferDroppedFrames(const AudioPlaneRingBuffer *ring);
uint64_t AudioPlaneRingBufferUnderrunFrames(const AudioPlaneRingBuffer *ring);

#endif
