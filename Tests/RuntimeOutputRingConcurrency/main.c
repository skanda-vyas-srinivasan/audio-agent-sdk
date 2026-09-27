#include "RealtimeAudioRing.h"

#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>

static SonexisAudioRingBuffer *ringBuffer;
static atomic_bool finished;

static void *produce(void *unused) {
    (void)unused;
    float samples[128 * 2];
    for (unsigned index = 0; index < 128 * 2; ++index) {
        samples[index] = (float)(index % 37) / 37.0f;
    }
    for (unsigned iteration = 0; iteration < 200000; ++iteration) {
        if (SonexisAudioRingBufferWriteInterleaved(ringBuffer, samples, 128) == 0) {
            sched_yield();
        }
    }
    atomic_store_explicit(&finished, true, memory_order_release);
    return NULL;
}

static void *consume(void *unused) {
    (void)unused;
    float samples[96 * 2];
    while (!atomic_load_explicit(&finished, memory_order_acquire) ||
           SonexisAudioRingBufferGetFillFrames(ringBuffer) != 0) {
        SonexisAudioRingBufferReadInterleaved(ringBuffer, samples, 96);
        sched_yield();
    }
    return NULL;
}

static void *flushRepeatedly(void *unused) {
    (void)unused;
    while (!atomic_load_explicit(&finished, memory_order_acquire)) {
        SonexisAudioRingBufferFlush(ringBuffer);
        assert(SonexisAudioRingBufferGetFillFrames(ringBuffer) <= 4096);
        sched_yield();
    }
    return NULL;
}

int main(void) {
    ringBuffer = SonexisAudioRingBufferCreate(4096, 2);
    assert(ringBuffer != NULL);
    atomic_init(&finished, false);

    pthread_t producer;
    pthread_t consumer;
    pthread_t flusher;
    assert(pthread_create(&producer, NULL, produce, NULL) == 0);
    assert(pthread_create(&consumer, NULL, consume, NULL) == 0);
    assert(pthread_create(&flusher, NULL, flushRepeatedly, NULL) == 0);
    assert(pthread_join(producer, NULL) == 0);
    assert(pthread_join(consumer, NULL) == 0);
    assert(pthread_join(flusher, NULL) == 0);

    assert(SonexisAudioRingBufferGetFillFrames(ringBuffer) <= 4096);
    SonexisAudioRingBufferDestroy(ringBuffer);
    puts("Runtime output ring concurrent flush/read/write stress passed");
    return 0;
}
