import Foundation

struct CaptureMetrics: Codable, Equatable, Sendable {
    let nativeFramesReceived: UInt64
    let normalizedFramesDelivered: UInt64
    let bytesDelivered: UInt64
    let ringDroppedFrames: UInt64
    let deliveryDroppedFrames: UInt64
    let conversionBatches: UInt64
    let conversionNanoseconds: UInt64
    let ringBacklogFrames: UInt32

    var averageConversionMicroseconds: Double {
        guard conversionBatches > 0 else { return 0 }
        return Double(conversionNanoseconds) / Double(conversionBatches) / 1_000.0
    }
}
