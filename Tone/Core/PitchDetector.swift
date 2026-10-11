import Foundation
import Accelerate

/// YIN difference function with a fixed comparison window and sub-sample interpolation.
/// Designed for one sustained voice or instrument; chords have no single reliable pitch.
struct PitchDetector {
    let minimumFrequency: Double = 55
    let maximumFrequency: Double = 1600
    let silenceThreshold: Double = 0.0005

    func detect(samples: [Float], sampleRate: Double) -> PitchReading? {
        guard sampleRate.isFinite, sampleRate > maximumFrequency * 2,
              samples.count >= 32, samples.allSatisfy({ $0.isFinite }) else { return nil }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        guard rms >= silenceThreshold else { return nil }
        let minLag = max(2, Int(sampleRate / maximumFrequency))
        let maxLag = min(Int(ceil(sampleRate / minimumFrequency)), samples.count / 2)
        guard maxLag > minLag + 2 else { return nil }
        let comparisonCount = samples.count - maxLag
        var difference = [Double](repeating: 0, count: maxLag + 1)
        var deltas = [Float](repeating: 0, count: comparisonCount)
        samples.withUnsafeBufferPointer { input in
            deltas.withUnsafeMutableBufferPointer { output in
                for lag in 1...maxLag {
                    vDSP_vsub(input.baseAddress!, 1, input.baseAddress! + lag, 1,
                              output.baseAddress!, 1, vDSP_Length(comparisonCount))
                    var sum: Float = 0
                    vDSP_svesq(output.baseAddress!, 1, &sum, vDSP_Length(comparisonCount))
                    difference[lag] = Double(sum)
                }
            }
        }
        var cumulative = 0.0
        var normalized = [Double](repeating: 1, count: maxLag + 1)
        for lag in 1...maxLag {
            cumulative += difference[lag]
            normalized[lag] = cumulative > 0 ? difference[lag] * Double(lag) / cumulative : 1
        }
        var candidate: Int?
        var lag = minLag
        while lag < maxLag {
            if normalized[lag] < 0.15 {
                while lag + 1 <= maxLag && normalized[lag + 1] < normalized[lag] { lag += 1 }
                candidate = lag
                break
            }
            lag += 1
        }
        // Natural voice has vibrato, breath and cycle-to-cycle variation. If the strict
        // threshold was never crossed, accept a strong global periodicity minimum.
        if candidate == nil {
            let best = (minLag...maxLag).min { normalized[$0] < normalized[$1] }!
            if normalized[best] < 0.3 { candidate = best }
        }
        guard let best = candidate, normalized[best] < 0.3 else { return nil }
        var refined = Double(best)
        if best > 0 && best < maxLag {
            // Interpolate the unnormalized difference: normalization tilts short periods
            // and can bias high notes by several cents.
            let left = difference[best - 1], center = difference[best], right = difference[best + 1]
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-12 {
                refined += max(-0.5, min(0.5, 0.5 * (left - right) / denominator))
            }
        }
        let frequency = sampleRate / refined
        // Allow a tiny interpolation tolerance at the nominal detection boundaries.
        guard frequency >= minimumFrequency * 0.999,
              frequency <= maximumFrequency * 1.001 else { return nil }
        return PitchReading(frequency: frequency, confidence: 1 - normalized[best])
    }
}
