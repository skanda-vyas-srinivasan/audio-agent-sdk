#include "RealtimeAudioRing.h"

#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

static SonexisAudioRingBuffer *ringBuffer;
static atomic_bool finished;
static const AudioTimeStamp emptyTimeStamp = {0};
static const AudioBufferList emptyInput = { .mNumberBuffers = 0 };

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
    float left[98];
    float right[98];
    AudioBufferList *output = calloc(1,
        offsetof(AudioBufferList, mBuffers) + (2 * sizeof(AudioBuffer)));
    assert(output != NULL);
    output->mNumberBuffers = 2;
    output->mBuffers[0].mNumberChannels = 1;
    output->mBuffers[0].mDataByteSize = 96 * sizeof(float);
    output->mBuffers[0].mData = &left[1];
    output->mBuffers[1].mNumberChannels = 1;
    output->mBuffers[1].mDataByteSize = 96 * sizeof(float);
    output->mBuffers[1].mData = &right[1];
    while (!atomic_load_explicit(&finished, memory_order_acquire) ||
           SonexisAudioRingBufferGetFillFrames(ringBuffer) != 0) {
        left[0] = left[97] = 1234.0f;
        right[0] = right[97] = 5678.0f;
        assert(SonexisAudioRingBufferIOProc(0, &emptyTimeStamp, &emptyInput, &emptyTimeStamp,
            output, &emptyTimeStamp, ringBuffer) == noErr);
        assert(left[0] == 1234.0f && left[97] == 1234.0f);
        assert(right[0] == 5678.0f && right[97] == 5678.0f);
        sched_yield();
    }
    free(output);
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
    SonexisAudioRingBuffer *shapeRing = SonexisAudioRingBufferCreate(8, 2);
    assert(shapeRing != NULL);
    float stereoInput[8] = { 0.1f, -0.1f, 0.2f, -0.2f,
        0.3f, -0.3f, 0.4f, -0.4f };
    assert(SonexisAudioRingBufferWriteInterleaved(shapeRing, stereoInput, 4) == 4);
    float stereoOutput[8] = {0};
    AudioBufferList interleaved = {
        .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 2, .mDataByteSize = sizeof(stereoOutput),
            .mData = stereoOutput }},
    };
    assert(SonexisAudioRingBufferIOProc(0, &emptyTimeStamp, &emptyInput, &emptyTimeStamp,
        &interleaved, &emptyTimeStamp, shapeRing) == noErr);
    for (unsigned index = 0; index < 8; ++index) {
        assert(stereoOutput[index] == stereoInput[index]);
    }
    SonexisAudioRingBufferDestroy(shapeRing);

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
