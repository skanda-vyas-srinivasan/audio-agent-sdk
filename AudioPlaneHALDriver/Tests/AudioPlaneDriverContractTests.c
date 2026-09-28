#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum {
    kAudioPlaneDeviceObject = 3,
    kAudioPlaneInputStreamObject = 4,
    kAudioPlaneInputDataSourceObject = 7,
    kAudioPlaneOutputStreamObject = 8,
};

typedef void *(*AudioPlaneFactory)(CFAllocatorRef, CFUUIDRef);

static OSStatus propertiesChanged(AudioServerPlugInHostRef host, AudioObjectID objectID,
                                  UInt32 count,
                                  const AudioObjectPropertyAddress *addresses)
{
    (void)host;
    (void)objectID;
    (void)count;
    (void)addresses;
    return noErr;
}

static OSStatus copyFromStorage(AudioServerPlugInHostRef host, CFStringRef key,
                                CFPropertyListRef *outData)
{
    (void)host;
    (void)key;
    *outData = NULL;
    return noErr;
}

static OSStatus writeToStorage(AudioServerPlugInHostRef host, CFStringRef key,
                               CFPropertyListRef data)
{
    (void)host;
    (void)key;
    (void)data;
    return noErr;
}

static OSStatus deleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key)
{
    (void)host;
    (void)key;
    return noErr;
}

static OSStatus requestConfigurationChange(AudioServerPlugInHostRef host,
                                           AudioObjectID objectID, UInt64 action,
                                           void *information)
{
    (void)host;
    (void)objectID;
    (void)action;
    (void)information;
    return noErr;
}

static const AudioServerPlugInHostInterface hostInterface = {
    propertiesChanged,
    copyFromStorage,
    writeToStorage,
    deleteFromStorage,
    requestConfigurationChange,
};

static void expectCFString(CFStringRef actual, CFStringRef expected)
{
    assert(actual != NULL);
    assert(CFStringCompare(actual, expected, 0) == kCFCompareEqualTo);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    void *bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if(bundle == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    AudioPlaneFactory factory = (AudioPlaneFactory)dlsym(bundle,
                                                          "AudioPlaneInput_Create");
    assert(factory != NULL);
    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)factory(
        kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    assert(driver != NULL);
    assert((*driver)->Initialize(driver, &hostInterface) == noErr);

    AudioObjectPropertyAddress nameAddress = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef name = NULL;
    UInt32 outputSize = 0;
    assert((*driver)->GetPropertyData(driver, kAudioPlaneDeviceObject, 0,
        &nameAddress, 0, NULL, sizeof(name), &outputSize, &name) == noErr);
    assert(outputSize == sizeof(name));
    expectCFString(name, CFSTR("AudioPlane Input"));

    AudioObjectPropertyAddress uidAddress = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef uid = NULL;
    assert((*driver)->GetPropertyData(driver, kAudioPlaneDeviceObject, 0,
        &uidAddress, 0, NULL, sizeof(uid), &outputSize, &uid) == noErr);
    expectCFString(uid, CFSTR("com.audioplane.input.device"));

    AudioObjectPropertyAddress dataSourceNameAddress = {
        kAudioSelectorControlPropertyItemName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 dataSourceItem = 0;
    CFStringRef dataSourceName = NULL;
    assert((*driver)->GetPropertyData(driver, kAudioPlaneInputDataSourceObject, 0,
        &dataSourceNameAddress, sizeof(dataSourceItem), &dataSourceItem,
        sizeof(dataSourceName), &outputSize, &dataSourceName) == noErr);
    expectCFString(dataSourceName, CFSTR("AudioPlane Input"));
    CFRelease(dataSourceName);

    AudioObjectPropertyAddress formatAddress = {
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioStreamBasicDescription format = {0};
    assert((*driver)->GetPropertyData(driver, kAudioPlaneInputStreamObject, 0,
        &formatAddress, 0, NULL, sizeof(format), &outputSize, &format) == noErr);
    assert(format.mSampleRate == 48000.0);
    assert(format.mFormatID == kAudioFormatLinearPCM);
    assert((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0);
    assert(format.mChannelsPerFrame == 2);
    assert(format.mBytesPerFrame == 8);

    Boolean willDo = false;
    Boolean inPlace = false;
    assert((*driver)->WillDoIOOperation(driver, kAudioPlaneDeviceObject, 7,
        kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace) == noErr);
    assert(willDo && inPlace);
    assert((*driver)->WillDoIOOperation(driver, kAudioPlaneDeviceObject, 7,
        kAudioServerPlugInIOOperationReadInput, &willDo, &inPlace) == noErr);
    assert(willDo && inPlace);

    assert((*driver)->StartIO(driver, kAudioPlaneDeviceObject, 7) == noErr);
    Float64 sampleTime = -1;
    UInt64 hostTime = 0;
    UInt64 seed = 0;
    assert((*driver)->GetZeroTimeStamp(driver, kAudioPlaneDeviceObject, 7,
        &sampleTime, &hostTime, &seed) == noErr);
    assert(sampleTime >= 0);
    assert(hostTime > 0);
    assert(seed == 1);

    enum { frameCount = 128, sampleCount = frameCount * 2 };
    float injected[sampleCount];
    float captured[sampleCount];
    for(size_t index = 0; index < sampleCount; ++index) {
        injected[index] = sinf((float)index * 0.07f) * 0.5f;
        captured[index] = 99.0f;
    }
    AudioServerPlugInIOCycleInfo cycle = {0};
    assert((*driver)->DoIOOperation(driver, kAudioPlaneDeviceObject,
        kAudioPlaneOutputStreamObject, 7, kAudioServerPlugInIOOperationWriteMix,
        frameCount, &cycle, injected, NULL) == noErr);
    assert((*driver)->DoIOOperation(driver, kAudioPlaneDeviceObject,
        kAudioPlaneInputStreamObject, 7, kAudioServerPlugInIOOperationReadInput,
        frameCount, &cycle, captured, NULL) == noErr);
    assert(memcmp(injected, captured, sizeof(injected)) == 0);

    memset(captured, 0x7f, sizeof(captured));
    assert((*driver)->DoIOOperation(driver, kAudioPlaneDeviceObject,
        kAudioPlaneInputStreamObject, 7, kAudioServerPlugInIOOperationReadInput,
        frameCount, &cycle, captured, NULL) == noErr);
    for(size_t index = 0; index < sampleCount; ++index) {
        assert(captured[index] == 0.0f);
    }

    assert((*driver)->StopIO(driver, kAudioPlaneDeviceObject, 7) == noErr);
    assert(dlclose(bundle) == 0);
    puts("AudioPlaneDriverContractTests passed");
    return 0;
}
