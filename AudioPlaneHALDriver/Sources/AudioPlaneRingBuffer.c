#include "AudioPlaneRingBuffer.h"

#include <stddef.h>
#include <string.h>

static void AudioPlaneCopyIntoRing(AudioPlaneRingBuffer *ring, uint64_t writeFrame,
                                   const float *source, uint32_t frameCount)
{
    const uint32_t firstFrame = (uint32_t)(writeFrame % ring->capacityFrames);
    uint32_t firstCount = ring->capacityFrames - firstFrame;
    if(firstCount > frameCount) {
        firstCount = frameCount;
    }
    const size_t firstSamples = (size_t)firstCount * ring->channels;
    memcpy(ring->samples + ((size_t)firstFrame * ring->channels), source,
           firstSamples * sizeof(float));

    const uint32_t secondCount = frameCount - firstCount;
    if(secondCount > 0) {
        memcpy(ring->samples, source + firstSamples,
               (size_t)secondCount * ring->channels * sizeof(float));
    }
}

static void AudioPlaneCopyOutOfRing(const AudioPlaneRingBuffer *ring, uint64_t readFrame,
                                    float *destination, uint32_t frameCount)
{
    const uint32_t firstFrame = (uint32_t)(readFrame % ring->capacityFrames);
    uint32_t firstCount = ring->capacityFrames - firstFrame;
    if(firstCount > frameCount) {
        firstCount = frameCount;
    }
    const size_t firstSamples = (size_t)firstCount * ring->channels;
    memcpy(destination, ring->samples + ((size_t)firstFrame * ring->channels),
           firstSamples * sizeof(float));

    const uint32_t secondCount = frameCount - firstCount;
    if(secondCount > 0) {
        memcpy(destination + firstSamples, ring->samples,
               (size_t)secondCount * ring->channels * sizeof(float));
    }
}

bool AudioPlaneRingBufferInitialize(AudioPlaneRingBuffer *ring, float *storage,
                                    uint32_t capacityFrames, uint32_t channels)
{
    if(ring == NULL || storage == NULL || capacityFrames == 0 || channels == 0) {
        return false;
    }
    ring->samples = storage;
    ring->capacityFrames = capacityFrames;
    ring->channels = channels;
    AudioPlaneRingBufferReset(ring);
    return true;
}

void AudioPlaneRingBufferReset(AudioPlaneRingBuffer *ring)
{
    if(ring == NULL) {
        return;
    }
    atomic_store_explicit(&ring->readFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->writeFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->droppedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->underrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->readPrimed, false, memory_order_relaxed);
}

uint32_t AudioPlaneRingBufferWrite(AudioPlaneRingBuffer *ring, const float *source,
                                   uint32_t frameCount)
{
    if(ring == NULL || source == NULL || frameCount == 0) {
        return 0;
    }

    const uint64_t writeFrame = atomic_load_explicit(&ring->writeFrame,
                                                      memory_order_relaxed);
    const uint64_t readFrame = atomic_load_explicit(&ring->readFrame,
                                                     memory_order_acquire);
    const uint64_t used = writeFrame - readFrame;
    const uint32_t freeFrames = used >= ring->capacityFrames
        ? 0 : ring->capacityFrames - (uint32_t)used;
    const uint32_t accepted = frameCount < freeFrames ? frameCount : freeFrames;

    if(accepted > 0) {
        AudioPlaneCopyIntoRing(ring, writeFrame, source, accepted);
        atomic_store_explicit(&ring->writeFrame, writeFrame + accepted,
                              memory_order_release);
    }
    if(accepted < frameCount) {
        atomic_fetch_add_explicit(&ring->droppedFrames, frameCount - accepted,
                                  memory_order_relaxed);
    }
    return accepted;
}

uint32_t AudioPlaneRingBufferRead(AudioPlaneRingBuffer *ring, float *destination,
                                  uint32_t frameCount)
{
    if(ring == NULL || destination == NULL || frameCount == 0) {
        return 0;
    }

    const uint64_t readFrame = atomic_load_explicit(&ring->readFrame,
                                                     memory_order_relaxed);
    const uint64_t writeFrame = atomic_load_explicit(&ring->writeFrame,
                                                      memory_order_acquire);
    const uint64_t available64 = writeFrame - readFrame;
    const uint32_t available = available64 > UINT32_MAX
        ? UINT32_MAX : (uint32_t)available64;
    const uint32_t copied = frameCount < available ? frameCount : available;

    if(copied > 0) {
        AudioPlaneCopyOutOfRing(ring, readFrame, destination, copied);
        atomic_store_explicit(&ring->readFrame, readFrame + copied,
                              memory_order_release);
    }
    if(copied < frameCount) {
        const uint32_t missing = frameCount - copied;
        memset(destination + ((size_t)copied * ring->channels), 0,
               (size_t)missing * ring->channels * sizeof(float));
        atomic_fetch_add_explicit(&ring->underrunFrames, missing,
                                  memory_order_relaxed);
    }
    return copied;
}

uint32_t AudioPlaneRingBufferReadPrimed(AudioPlaneRingBuffer *ring, float *destination,
                                        uint32_t frameCount, uint32_t primeFrameCount)
{
    if(ring == NULL || destination == NULL || frameCount == 0) {
        return 0;
    }

    uint32_t threshold = primeFrameCount;
    if(threshold < frameCount) {
        threshold = frameCount;
    }
    if(threshold > ring->capacityFrames) {
        threshold = ring->capacityFrames;
    }
    if(!atomic_load_explicit(&ring->readPrimed, memory_order_acquire)) {
        if(AudioPlaneRingBufferQueuedFrames(ring) < threshold) {
            memset(destination, 0,
                   (size_t)frameCount * ring->channels * sizeof(float));
            return 0;
        }
        atomic_store_explicit(&ring->readPrimed, true, memory_order_release);
    }

    const uint32_t copied = AudioPlaneRingBufferRead(ring, destination, frameCount);
    if(copied < frameCount) {
        // A real transport gap occurred. Require the bounded safety cushion to
        // refill before exposing more samples so callback scheduling jitter
        // cannot alternate tiny audio fragments with silence.
        atomic_store_explicit(&ring->readPrimed, false, memory_order_release);
    }
    return copied;
}

uint32_t AudioPlaneRingBufferQueuedFrames(const AudioPlaneRingBuffer *ring)
{
    if(ring == NULL) {
        return 0;
    }
    const uint64_t readFrame = atomic_load_explicit(&ring->readFrame,
                                                     memory_order_acquire);
    const uint64_t writeFrame = atomic_load_explicit(&ring->writeFrame,
                                                      memory_order_acquire);
    const uint64_t queued = writeFrame - readFrame;
    return queued > UINT32_MAX ? UINT32_MAX : (uint32_t)queued;
}

uint64_t AudioPlaneRingBufferDroppedFrames(const AudioPlaneRingBuffer *ring)
{
    return ring == NULL ? 0 : atomic_load_explicit(&ring->droppedFrames,
                                                    memory_order_relaxed);
}

uint64_t AudioPlaneRingBufferUnderrunFrames(const AudioPlaneRingBuffer *ring)
{
    return ring == NULL ? 0 : atomic_load_explicit(&ring->underrunFrames,
                                                    memory_order_relaxed);
}
