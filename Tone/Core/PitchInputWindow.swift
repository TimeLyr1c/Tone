import Foundation

/// Capture every sample even when analysis skips a window. Audio must remain contiguous.
struct PitchInputWindow {
    let sampleRate: Double
    private let size: Int
    private let hop: Int
    private var samples: [Float] = []
    private var sinceEmission = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        size = max(2048, Int(sampleRate * 0.18))
        hop = max(1, Int(sampleRate * 0.08))
    }

    mutating func append(_ chunk: [Float]) -> [Float]? {
        samples.append(contentsOf: chunk)
        sinceEmission += chunk.count
        if samples.count > size { samples.removeFirst(samples.count - size) }
        guard samples.count == size, sinceEmission >= hop else { return nil }
        sinceEmission = 0
        return samples
    }

    static func downsample(_ samples: [Float], sampleRate: Double) -> (samples: [Float], rate: Double) {
        let strideSize = max(1, Int(sampleRate / 12000))
        guard samples.count >= strideSize else { return ([], sampleRate / Double(strideSize)) }
        var reduced: [Float] = []
        reduced.reserveCapacity(samples.count / strideSize)
        for index in stride(from: 0, through: samples.count - strideSize, by: strideSize) {
            var total: Float = 0
            for offset in 0..<strideSize { total += samples[index + offset] }
            reduced.append(total / Float(strideSize))
        }
        return (reduced, sampleRate / Double(strideSize))
    }
}
