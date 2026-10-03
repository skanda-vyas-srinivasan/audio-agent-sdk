import AVFoundation
import Foundation

enum AudioNormalizationError: Error, CustomStringConvertible {
    case unsupportedInputFormat(sampleRate: Double, channels: UInt32)
    case converterCreationFailed
    case bufferAllocationFailed
    case conversionFailed(String)

    var description: String {
        switch self {
        case .unsupportedInputFormat(let sampleRate, let channels):
            return "Unsupported capture format: \(sampleRate) Hz, \(channels) channels"
        case .converterCreationFailed:
            return "Could not create the Runtime audio converter"
        case .bufferAllocationFailed:
            return "Could not allocate Runtime conversion buffers"
        case .conversionFailed(let message):
            return "Runtime audio conversion failed: \(message)"
        }
    }
}

/// Stateful AVAudioConverter wrapper. It is confined to a capture worker queue;
/// none of its allocation or conversion work is reachable from the HAL callback.
final class RuntimeAudioNormalizer {
    static let supportedInputSampleRates = 8_000.0...192_000.0
    static let supportedInputChannels: ClosedRange<UInt32> = 1...8

    static func validateInputFormat(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate.isFinite,
              supportedInputSampleRates.contains(sampleRate),
              supportedInputChannels.contains(channels) else {
            throw AudioNormalizationError.unsupportedInputFormat(
                sampleRate: sampleRate, channels: channels)
        }
    }

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let maxInputFrames: AVAudioFrameCount

    init(sampleRate: Double, channels: UInt32,
         output: RuntimePCMFormat = .pcm16Mono16kHz,
         maxInputFrames: AVAudioFrameCount = 2_048) throws {
        try Self.validateInputFormat(sampleRate: sampleRate, channels: channels)
        let outputCommonFormat: AVAudioCommonFormat = output.sampleFormat == .pcmS16LE
            ? .pcmFormatInt16 : .pcmFormatFloat32
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ), let outputFormat = AVAudioFormat(
            commonFormat: outputCommonFormat,
            sampleRate: Double(output.sampleRate),
            channels: AVAudioChannelCount(output.channelCount),
            interleaved: true
        ) else {
            throw AudioNormalizationError.unsupportedInputFormat(sampleRate: sampleRate, channels: channels)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioNormalizationError.converterCreationFailed
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(maxInputFrames) * ratio)) + 64
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxInputFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioNormalizationError.bufferAllocationFailed
        }

        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        self.maxInputFrames = maxInputFrames
    }

    func resetAfterDiscontinuity() {
        converter.reset()
    }

    func convert(samples: UnsafePointer<Float>, frameCount: UInt32) throws -> Data {
        guard frameCount > 0 else { return Data() }
        guard frameCount <= maxInputFrames else {
            throw AudioNormalizationError.conversionFailed("input exceeded prepared buffer capacity")
        }

        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        let inputBytes = Int(frameCount) * Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        guard let inputData = inputBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw AudioNormalizationError.bufferAllocationFailed
        }
        inputData.copyMemory(from: samples, byteCount: inputBytes)
        outputBuffer.frameLength = 0

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return self.inputBuffer
        }
        if status == .error || conversionError != nil {
            throw AudioNormalizationError.conversionFailed(
                conversionError?.localizedDescription ?? "AVAudioConverter returned an error"
            )
        }

        let byteCount = Int(outputBuffer.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        guard byteCount > 0 else { return Data() }
        guard let outputData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw AudioNormalizationError.bufferAllocationFailed
        }
        return Data(bytes: outputData, count: byteCount)
    }
}
