#include "AudioPlaneRingBuffer.h"

#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static void expectSample(float actual, float expected)
{
    assert(fabsf(actual - expected) < 0.000001f);
}

static void testBasicWriteRead(void)
{
    float storage[16] = {0};
    AudioPlaneRingBuffer ring;
    assert(AudioPlaneRingBufferInitialize(&ring, storage, 8, 2));
    const float input[] = {1, 2, 3, 4, 5, 6};
    float output[6] = {0};
    assert(AudioPlaneRingBufferWrite(&ring, input, 3) == 3);
    assert(AudioPlaneRingBufferQueuedFrames(&ring) == 3);
    assert(AudioPlaneRingBufferRead(&ring, output, 3) == 3);
    assert(memcmp(input, output, sizeof(input)) == 0);
    assert(AudioPlaneRingBufferQueuedFrames(&ring) == 0);
}

static void testWrap(void)
{
    float storage[8] = {0};
    AudioPlaneRingBuffer ring;
    assert(AudioPlaneRingBufferInitialize(&ring, storage, 4, 2));
    const float first[] = {1, 2, 3, 4, 5, 6};
    const float second[] = {7, 8, 9, 10, 11, 12};
    float discarded[4] = {0};
    float output[8] = {0};
    assert(AudioPlaneRingBufferWrite(&ring, first, 3) == 3);
    assert(AudioPlaneRingBufferRead(&ring, discarded, 2) == 2);
    assert(AudioPlaneRingBufferWrite(&ring, second, 3) == 3);
    assert(AudioPlaneRingBufferRead(&ring, output, 4) == 4);
    const float expected[] = {5, 6, 7, 8, 9, 10, 11, 12};
    assert(memcmp(expected, output, sizeof(expected)) == 0);
}

static void testOverflowDropsNewest(void)
{
    float storage[4] = {0};
    AudioPlaneRingBuffer ring;
    assert(AudioPlaneRingBufferInitialize(&ring, storage, 2, 2));
    const float input[] = {1, 2, 3, 4, 5, 6};
    float output[4] = {0};
    assert(AudioPlaneRingBufferWrite(&ring, input, 3) == 2);
    assert(AudioPlaneRingBufferDroppedFrames(&ring) == 1);
    assert(AudioPlaneRingBufferRead(&ring, output, 2) == 2);
    expectSample(output[0], 1);
    expectSample(output[3], 4);
}

static void testUnderrunFillsSilence(void)
{
    float storage[4] = {0};
    AudioPlaneRingBuffer ring;
    assert(AudioPlaneRingBufferInitialize(&ring, storage, 2, 2));
    const float input[] = {0.25f, -0.25f};
    float output[] = {9, 9, 9, 9, 9, 9};
    assert(AudioPlaneRingBufferWrite(&ring, input, 1) == 1);
    assert(AudioPlaneRingBufferRead(&ring, output, 3) == 1);
    expectSample(output[0], 0.25f);
    expectSample(output[1], -0.25f);
    expectSample(output[2], 0);
    expectSample(output[5], 0);
    assert(AudioPlaneRingBufferUnderrunFrames(&ring) == 2);
}

typedef struct StressContext {
    AudioPlaneRingBuffer *ring;
    _Atomic bool producerDone;
    _Atomic uint64_t consumed;
} StressContext;

static void *producer(void *opaque)
{
    StressContext *context = opaque;
    float block[64 * 2];
    for(size_t index = 0; index < sizeof(block) / sizeof(block[0]); ++index) {
        block[index] = (float)(index % 31) / 31.0f;
    }
    for(uint32_t iteration = 0; iteration < 10000; ++iteration) {
        (void)AudioPlaneRingBufferWrite(context->ring, block, 64);
    }
    atomic_store_explicit(&context->producerDone, true, memory_order_release);
    return NULL;
}

static void *consumer(void *opaque)
{
    StressContext *context = opaque;
    float block[64 * 2];
    do {
        const uint32_t count = AudioPlaneRingBufferRead(context->ring, block, 64);
        atomic_fetch_add_explicit(&context->consumed, count, memory_order_relaxed);
    } while(!atomic_load_explicit(&context->producerDone, memory_order_acquire)
            || AudioPlaneRingBufferQueuedFrames(context->ring) > 0);
    return NULL;
}

static void testConcurrentStress(void)
{
    float storage[1024 * 2] = {0};
    AudioPlaneRingBuffer ring;
    assert(AudioPlaneRingBufferInitialize(&ring, storage, 1024, 2));
    StressContext context = {.ring = &ring, .producerDone = false, .consumed = 0};
    pthread_t producerThread;
    pthread_t consumerThread;
    assert(pthread_create(&producerThread, NULL, producer, &context) == 0);
    assert(pthread_create(&consumerThread, NULL, consumer, &context) == 0);
    assert(pthread_join(producerThread, NULL) == 0);
    assert(pthread_join(consumerThread, NULL) == 0);
    const uint64_t accepted = 10000ULL * 64
        - AudioPlaneRingBufferDroppedFrames(&ring);
    assert(atomic_load_explicit(&context.consumed, memory_order_relaxed) == accepted);
    assert(AudioPlaneRingBufferQueuedFrames(&ring) == 0);
}

int main(void)
{
    testBasicWriteRead();
    testWrap();
    testOverflowDropsNewest();
    testUnderrunFillsSilence();
    testConcurrentStress();
    puts("AudioPlaneRingBufferTests passed");
    return 0;
}
