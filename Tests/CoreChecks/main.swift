// Runs without XCTest or Xcode; compile together with Tone/Core/*.swift.
import Foundation

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

func signal(_ frequency: Double, rate: Double = 12000, amplitude: Double = 0.4,
            harmonics: [Double] = [1]) -> [Float] {
    (0..<Int(rate * 0.18)).map { index in
        let phase = 2 * Double.pi * frequency * Double(index) / rate
        return Float(amplitude * harmonics.enumerated().reduce(0.0) {
            $0 + $1.element * sin(Double($1.offset + 1) * phase)
        })
    }
}

let detector = PitchDetector()
check(MusicalNote(midi: 60).label == "C4", "Central C label")
check(abs(MusicalNote(midi: 60).frequency() - 261.625565) < 0.00001, "Central C frequency")
check(MusicalNote(midi: 69).frequency() == 440, "Standard A frequency")
check(MusicalNote(midi: 61).label == "C♯4", "Accidental label")
for cents in [-49.0, -25, -5, 0, 5, 25, 49] {
    let pitch = PitchReading(frequency: 440 * pow(2, cents / 1200))
    check(pitch?.note.midi == 69 && abs((pitch?.cents ?? 999) - cents) < 0.000001,
          "Nearest note and signed cents: \(cents)")
}
check(PitchReading(frequency: 440 * pow(2, 51.0 / 1200))?.note.midi == 70, "Nearest note boundary")
for frequency in [55.0, 65.406, 82.407, 110, 196, 261.625565, 440, 880, 1046.502, 1567.982] {
    let pitch = detector.detect(samples: signal(frequency), sampleRate: 12000)
    check(pitch != nil, "Detect \(frequency) Hz")
    if let pitch {
        check(abs(1200 * log2(pitch.frequency / frequency)) < 3, "Accuracy within 3 cents: \(frequency) Hz")
        check(pitch.confidence > 0.8, "Confidence: \(frequency) Hz")
    }
}
for cents in [-30.0, 30] {
    let pitch = detector.detect(samples: signal(440 * pow(2, cents / 1200)), sampleRate: 12000)
    check(pitch?.note.midi == 69 && abs((pitch?.cents ?? 999) - cents) < 2, "Detuned A: \(cents) cents")
}
for frequency in [110.0, 220, 440] {
    let pitch = detector.detect(samples: signal(frequency, amplitude: 0.2, harmonics: [0.5, 1, 0.3]), sampleRate: 12000)
    check(pitch != nil && abs(1200 * log2((pitch?.frequency ?? 1) / frequency)) < 3,
          "Stronger second harmonic: \(frequency) Hz")
}
check(detector.detect(samples: [Float](repeating: 0, count: 2160), sampleRate: 12000) == nil, "Silence")
check(detector.detect(samples: [Float](repeating: 0.5, count: 2160), sampleRate: 12000) == nil, "DC input")
check(detector.detect(samples: signal(440, amplitude: 0.0001), sampleRate: 12000) == nil, "Below noise floor")
check(detector.detect(samples: [], sampleRate: 12000) == nil, "Empty input")
check(detector.detect(samples: signal(440), sampleRate: 0) == nil, "Invalid sample rate")
check(detector.detect(samples: [Float](repeating: .nan, count: 2160), sampleRate: 12000) == nil, "Nonfinite samples")
check(PitchReading(frequency: .nan) == nil && PitchReading(frequency: 0) == nil, "Invalid frequency")
var seed: UInt64 = 42
let noise: [Float] = (0..<2160).map { _ in
    seed = seed &* 6364136223846793005 &+ 1
    return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5)
}
check(detector.detect(samples: noise, sampleRate: 12000) == nil, "Aperiodic noise")
for rate in [44100.0, 48000, 96000] {
    let samples = signal(261.625565, rate: rate)
    let strideSize = max(1, Int(rate / 12000))
    let reduced: [Float] = stride(from: 0, through: samples.count - strideSize, by: strideSize).map { index in
        samples[index..<(index + strideSize)].reduce(0, +) / Float(strideSize)
    }
    let pitch = detector.detect(samples: reduced, sampleRate: rate / Double(strideSize))
    check(pitch?.note.midi == 60 && abs(pitch?.cents ?? 999) < 2, "Input sample rate: \(rate)")
}
for midi in 60..<72 {
    let note = MusicalNote(midi: midi)
    check(SungNoteRole.unknown.tonicCandidate(from: note) == nil, "Unknown role has no inferred tonic")
    check(SungNoteRole.tonic.tonicCandidate(from: note) == note, "Tonic role: \(note.label)")
    check(SungNoteRole.dominant.tonicCandidate(from: note)?.midi == midi - 7, "Dominant role: \(note.label)")
}
check(SungNoteRole.dominant.tonicCandidate(from: MusicalNote(midi: 67))?.name == "C", "G dominant -> C tonic")
check(SungNoteRole.dominant.tonicCandidate(from: MusicalNote(midi: 60))?.name == "F", "C dominant -> F tonic")

// Measure the actual oscillator used by AVAudioSourceNode rather than a separate sine fixture.
// Average fractional zero-crossing intervals after the attack to verify output pitch.
func measuredFrequency(_ samples: [Float], rate: Double) -> Double? {
    var crossings: [Double] = []
    for index in Int(rate * 0.05)..<(samples.count - 1) {
        if samples[index] <= 0 && samples[index + 1] > 0 {
            let fraction = -Double(samples[index]) / Double(samples[index + 1] - samples[index])
            crossings.append(Double(index) + fraction)
        }
    }
    guard let first = crossings.first, let last = crossings.last, crossings.count > 2 else { return nil }
    return rate * Double(crossings.count - 1) / (last - first)
}

for rate in [8000.0, 44100, 48000, 96000] {
    for midi in [36, 60, 69, 84, 96] {
        let frequency = MusicalNote(midi: midi).frequency()
        var oscillator = SineOscillator(sampleRate: rate)!
        oscillator.set(frequency: frequency, amplitude: 0.22)
        let samples = (0..<Int(rate * 0.35)).map { _ in oscillator.nextSample() }
        let measured = measuredFrequency(samples, rate: rate)
        check(measured != nil && abs(1200 * log2((measured ?? 1) / frequency)) < 0.1,
              "Rendered standard note \(midi) at \(rate) Hz sample rate")
        check(samples.allSatisfy { $0.isFinite && abs($0) <= 0.220001 }, "Output amplitude bound")
        check(samples.first == 0 && abs(samples[1]) < 0.02, "Gradual attack")
        oscillator.set(frequency: frequency, amplitude: 0)
        let release = (0..<Int(rate * 0.06)).map { _ in oscillator.nextSample() }
        check(release.suffix(16).allSatisfy { abs($0) < 0.00001 }, "Release reaches silence within 60 ms")
    }
}
var contiguous = SineOscillator(sampleRate: 48000)!
var chunked = SineOscillator(sampleRate: 48000)!
contiguous.set(frequency: 440, amplitude: 0.22)
chunked.set(frequency: 440, amplitude: 0.22)
let contiguousSamples = (0..<4096).map { _ in contiguous.nextSample() }
var chunkedSamples: [Float] = []
for _ in 0..<4 {
    chunked.set(frequency: 440, amplitude: 0.22)
    chunkedSamples.append(contentsOf: (0..<1024).map { _ in chunked.nextSample() })
}
check(contiguousSamples == chunkedSamples, "Phase and amplitude continuous across render buffers")
check(SineOscillator(sampleRate: 0) == nil && SineOscillator(sampleRate: .nan) == nil,
      "Invalid output sample rates rejected")
chunked.set(frequency: .nan, amplitude: 1)
let invalidRelease = (0..<2880).map { _ in chunked.nextSample() }
check(invalidRelease.allSatisfy { $0.isFinite } && abs(invalidRelease.last!) < 0.00001,
      "Invalid frequency releases to silence")
// Quiet human/instrument pitches below B4 must not be discarded by a loudness gate.
for frequency in [82.407, 110, 130.813, 220, 261.626, 440, 493.883] {
    for amplitude in [0.001, 0.003] {
        let pitch = detector.detect(samples: signal(frequency, amplitude: amplitude, harmonics: [1, 0.7, 0.3]), sampleRate: 12000)
        check(pitch != nil && abs(1200 * log2((pitch?.frequency ?? 1) / frequency)) < 3,
              "Quiet rich-harmonic pitch \(frequency) at amplitude \(amplitude)")
    }
}

// Feed the actual capture-window and downsampling code with irregular audio callbacks.
// Skip analysis on alternate windows as if the worker were busy, but capture never skips audio.
for frequency in [110.0, 220, 440] {
    let rate = 48000.0
    var phase = 0.0
    let voice: [Float] = (0..<48000).map { index in
        let time = Double(index) / rate
        let instantaneousFrequency = frequency * (1 + 0.005 * sin(2 * .pi * 5 * time))
        phase += 2 * .pi * instantaneousFrequency / rate
        return Float(0.003 * (sin(phase) + 0.6 * sin(2 * phase) + 0.25 * sin(3 * phase)))
    }
    var accumulator = PitchInputWindow(sampleRate: rate)
    var position = 0, chunkIndex = 0, windowIndex = 0, accepted = 0
    let sizes = [512, 2048, 480, 4096]
    while position < voice.count {
        let end = min(voice.count, position + sizes[chunkIndex % sizes.count])
        let window = accumulator.append(Array(voice[position..<end]))
        position = end
        chunkIndex += 1
        guard let window else { continue }
        check(window == Array(voice[(end - window.count)..<end]), "Capture window is contiguous")
        windowIndex += 1
        if windowIndex % 2 == 0 { continue }
        let reduced = PitchInputWindow.downsample(window, sampleRate: rate)
        let pitch = detector.detect(samples: reduced.samples, sampleRate: reduced.rate)
        check(pitch != nil && abs(1200 * log2((pitch?.frequency ?? 1) / frequency)) < 15,
              "Quiet vibrato voice \(frequency) through capture pipeline")
        if pitch != nil { accepted += 1 }
    }
    check(accepted >= 3, "Repeated live-style detections below B4")
}
print("\(checks - failures)/\(checks) checks passed.")
if failures > 0 { exit(1) }
