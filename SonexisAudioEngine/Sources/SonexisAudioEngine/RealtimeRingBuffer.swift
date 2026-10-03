import CoreAudio
import Foundation
import SonexisAudioEngineC

public final class RealtimeRingBuffer {
    private var pointer: OpaquePointer?

    /// Stable for this wrapper's lifetime. Callback contexts retain the
    /// wrapper separately and use this pointer to avoid Swift dispatch/ARC in
    /// the realtime render callback.
    public var realtimePointer: OpaquePointer? { pointer }

    public let capacityFrames: UInt32
    public let channels: UInt32

    public convenience init(capacityFrames: UInt32, channels: UInt32) throws {
        try self.init(capacityFrames: capacityFrames, channels: channels, trackCaptureDrops: false)
    }

    public init(capacityFrames: UInt32, channels: UInt32, trackCaptureDrops: Bool) throws {
        let allocated = trackCaptureDrops
            ? SonexisAudioRingBufferCreateForCapture(capacityFrames, channels)
            : SonexisAudioRingBufferCreate(capacityFrames, channels)
        guard let pointer = allocated else {
            throw SonexisError(message: "Could not allocate realtime audio ring buffer")
        }

        self.pointer = pointer
        self.capacityFrames = capacityFrames
        self.channels = channels
    }

    deinit {
        destroy()
    }

    public func write(inputData: UnsafePointer<AudioBufferList>) -> UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferWriteFromAudioBufferList(pointer, inputData)
    }

    public func writeInterleaved(_ samples: UnsafePointer<Float>, frames: UInt32) -> UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferWriteInterleaved(pointer, samples, frames)
    }

    public func read(outputData: UnsafeMutablePointer<AudioBufferList>) -> UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferReadToAudioBufferList(pointer, outputData)
    }

    public func readInterleaved(_ samples: UnsafeMutablePointer<Float>, frames: UInt32) -> UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferReadInterleaved(pointer, samples, frames)
    }

    /// Returns a contiguous run of native capture samples and its preceding loss.
    public func readCaptureInterleaved(_ samples: UnsafeMutablePointer<Float>, frames: UInt32,
                                       droppedFramesBefore: inout UInt64) -> UInt32 {
        droppedFramesBefore = 0
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferReadCaptureInterleaved(
            pointer, samples, frames, &droppedFramesBefore)
    }

    public func flush() -> UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferFlush(pointer)
    }

    public func setGainImmediate(_ gain: Float) {
        guard let pointer else { return }
        SonexisAudioRingBufferSetGainImmediate(pointer, gain)
    }

    public func requestGainRamp(targetGain: Float, rampFrames: UInt32) {
        guard let pointer else { return }
        SonexisAudioRingBufferRequestGainRamp(pointer, targetGain, rampFrames)
    }

    public func setReadEnabled(_ enabled: Bool) {
        guard let pointer else { return }
        SonexisAudioRingBufferSetReadEnabled(pointer, enabled)
    }

    /// Control-thread barrier used after a callback is unregistered and before
    /// releasing its retained ring context.
    public func quiesceReads() {
        guard let pointer else { return }
        SonexisAudioRingBufferQuiesceReads(pointer)
    }

    public func setTargetFillFrames(_ frames: UInt32) {
        guard let pointer else { return }
        SonexisAudioRingBufferSetTargetFillFrames(pointer, frames)
    }

    public var fillFrames: UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetFillFrames(pointer)
    }

    public var writableFrames: UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetWritableFrames(pointer)
    }

    public var droppedFrames: UInt64 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetDroppedFrames(pointer)
    }

    public var underflowFrames: UInt64 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetUnderflowFrames(pointer)
    }

    public var writtenFrames: UInt64 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetWrittenFrames(pointer)
    }

    public var writeOperations: UInt64 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetWriteOperations(pointer)
    }

    public var readFrames: UInt64 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetReadFrames(pointer)
    }

    public var renderedFrames: UInt64 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetRenderedFrames(pointer)
    }

    public var lastInputPeakPPM: UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetLastInputPeakPPM(pointer)
    }

    public var targetFillFrames: UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetTargetFillFrames(pointer)
    }

    public var currentGainPPM: UInt32 {
        guard let pointer else { return 0 }
        return SonexisAudioRingBufferGetCurrentGainPPM(pointer)
    }

    public func destroy() {
        guard let pointer else { return }
        SonexisAudioRingBufferDestroy(pointer)
        self.pointer = nil
    }
}
