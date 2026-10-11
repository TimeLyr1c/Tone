import Foundation

/// Own this value on the audio render thread. Controls are updated once per buffer.
/// No allocation or synchronization occurs while producing individual samples.
struct SineOscillator {
    private let sampleRate: Double
    private let smoothing: Double
    private var phase = 0.0
    private var phaseIncrement = 0.0
    private var amplitude = 0.0
    private var targetAmplitude = 0.0

    init?(sampleRate: Double) {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate) else { return nil }
        self.sampleRate = sampleRate
        smoothing = 1 - exp(-1 / (sampleRate * 0.005))
    }

    mutating func set(frequency: Double, amplitude: Double) {
        guard frequency.isFinite, frequency > 0, frequency < sampleRate / 2,
              amplitude.isFinite else {
            targetAmplitude = 0
            return
        }
        phaseIncrement = 2 * Double.pi * frequency / sampleRate
        targetAmplitude = max(0, min(1, amplitude))
    }

    mutating func nextSample() -> Float {
        amplitude += (targetAmplitude - amplitude) * smoothing
        let sample = Float(sin(phase) * amplitude)
        phase += phaseIncrement
        if phase >= 2 * .pi { phase -= 2 * .pi }
        return sample
    }
}
