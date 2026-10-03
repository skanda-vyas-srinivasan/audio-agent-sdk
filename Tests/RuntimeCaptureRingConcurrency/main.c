#include "RealtimeAudioRing.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>

static SonexisAudioRingBuffer *ring;
static atomic_bool ready, started, finished;
static const uint32_t attempts = 200000;

static void *produce(void *unused) {
    (void)unused;
    for (uint32_t frame = 0; frame < attempts; ++frame) {
        // Encode identity as exact, normalized Float32 PCM rather than pushing
        // the peak diagnostic outside its representable input range.
        float value = (float)frame / 262144.0f;
        float samples[2] = {value, -value};
        if (frame % 2) {
            SonexisAudioRingBufferWriteInterleaved(ring, samples, 1);
        } else {
            struct { UInt32 count; AudioBuffer buffers[2]; } input = {
                2, {{1, sizeof(float), &samples[0]}, {1, sizeof(float), &samples[1]}}
            };
            AudioTimeStamp time = {0};
            AudioBufferList output = {0};
            SonexisAudioRingBufferInputIOProc(0, &time, (AudioBufferList *)&input,
                                            &time, &output, &time, ring);
        }
        if (frame == 63) {
            // Force overflow before the first read, then exercise concurrent
            // post-gap writes through both real native write entry points.
            atomic_store_explicit(&ready, true, memory_order_release);
            while (!atomic_load_explicit(&started, memory_order_acquire)) sched_yield();
        }
    }
    atomic_store_explicit(&finished, true, memory_order_release);
    return NULL;
}

static void *consume(void *unused) {
    (void)unused;
    while (!atomic_load_explicit(&ready, memory_order_acquire)) sched_yield();
    uint64_t expected = 0, received = 0;
    do {
        float samples[128];
        uint64_t drops;
        uint32_t count = SonexisAudioRingBufferReadCaptureInterleaved(ring, samples, 64, &drops);
        if (count == 0) assert(drops == 0);
        expected += drops;
        for (uint32_t frame = 0; frame < count; ++frame) {
            float value = (float)expected / 262144.0f;
            assert(samples[2 * frame] == value);
            assert(samples[2 * frame + 1] == -value);
            ++expected;
            ++received;
        }
        atomic_store_explicit(&started, true, memory_order_release);
        sched_yield();
    } while (!atomic_load_explicit(&finished, memory_order_acquire) ||
             SonexisAudioRingBufferGetFillFrames(ring) > 0);
    assert(SonexisAudioRingBufferGetDroppedFrames(ring) >= 32);
    assert(received + SonexisAudioRingBufferGetDroppedFrames(ring) == attempts);
    return NULL;
}

int main(void) {
    ring = SonexisAudioRingBufferCreateForCapture(32, 2);
    assert(ring != NULL);
    atomic_init(&ready, false);
    atomic_init(&started, false);
    atomic_init(&finished, false);
    pthread_t producer, consumer;
    assert(pthread_create(&producer, NULL, produce, NULL) == 0);
    assert(pthread_create(&consumer, NULL, consume, NULL) == 0);
    assert(pthread_join(producer, NULL) == 0);
    assert(pthread_join(consumer, NULL) == 0);
    SonexisAudioRingBufferDestroy(ring);
    puts("Runtime capture ring concurrent loss chronology passed");
    return 0;
}
