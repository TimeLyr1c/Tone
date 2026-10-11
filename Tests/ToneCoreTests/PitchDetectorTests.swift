import Foundation
import XCTest
@testable import ToneCore

final class PitchDetectorTests: XCTestCase {
    private let detector = PitchDetector()
    private let sampleRate = 12000.0

    private func signal(_ frequency: Double, amplitude: Double = 0.4,
                        harmonics: [Double] = [1], rate: Double = 12000) -> [Float] {
        (0..<Int(rate * 0.18)).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / rate
            return Float(amplitude * harmonics.enumerated().reduce(0.0) {
                $0 + $1.element * sin(Double($1.offset + 1) * phase)
            })
        }
    }

    func testStandardNotes() {
        XCTAssertEqual(MusicalNote(midi: 60).label, "C4")
        XCTAssertEqual(MusicalNote(midi: 60).frequency(), 261.625565, accuracy: 0.00001)
        XCTAssertEqual(MusicalNote(midi: 69).frequency(), 440)
        XCTAssertEqual(MusicalNote(midi: 61).label, "C♯4")
        XCTAssertEqual(MusicalNote(midi: 72).label, "C5")
    }

    func testNearestNoteAndCentsDirection() throws {
        for cents in [-49.0, -25, -5, 0, 5, 25, 49] {
            let reading = try XCTUnwrap(PitchReading(frequency: 440 * pow(2, cents / 1200)))
            XCTAssertEqual(reading.note.midi, 69)
            XCTAssertEqual(reading.cents, cents, accuracy: 0.000001)
        }
        XCTAssertEqual(PitchReading(frequency: 440 * pow(2, 51.0 / 1200))?.note.midi, 70)
        XCTAssertNil(PitchReading(frequency: 0))
        XCTAssertNil(PitchReading(frequency: .nan))
        XCTAssertNil(PitchReading(frequency: .infinity))
    }

    func testDetectsVoiceAndInstrumentRange() throws {
        for frequency in [55.0, 65.406, 82.407, 110, 196, 261.625565, 440, 880, 1046.502, 1567.982] {
            let reading = try XCTUnwrap(detector.detect(samples: signal(frequency), sampleRate: sampleRate), "\(frequency) Hz")
            let centsError = 1200 * log2(reading.frequency / frequency)
            XCTAssertEqual(centsError, 0, accuracy: 3, "\(frequency) Hz")
            XCTAssertGreaterThan(reading.confidence, 0.8)
        }
    }

    func testDetunedNoteDetection() throws {
        for cents in [-30.0, 30.0] {
            let frequency = 440 * pow(2, cents / 1200)
            let reading = try XCTUnwrap(detector.detect(samples: signal(frequency), sampleRate: sampleRate))
            XCTAssertEqual(reading.note.midi, 69)
            XCTAssertEqual(reading.cents, cents, accuracy: 2)
        }
    }

    func testFindsFundamentalWithStrongerSecondHarmonic() throws {
        for frequency in [110.0, 220, 440] {
            let samples = signal(frequency, amplitude: 0.2, harmonics: [0.5, 1, 0.3])
            let reading = try XCTUnwrap(detector.detect(samples: samples, sampleRate: sampleRate))
            XCTAssertEqual(1200 * log2(reading.frequency / frequency), 0, accuracy: 3)
        }
    }

    func testRejectsSilenceDCNoiseAndInvalidInput() {
        XCTAssertNil(detector.detect(samples: [Float](repeating: 0, count: 2160), sampleRate: sampleRate))
        XCTAssertNil(detector.detect(samples: [Float](repeating: 0.5, count: 2160), sampleRate: sampleRate))
        XCTAssertNil(detector.detect(samples: signal(440, amplitude: 0.0001), sampleRate: sampleRate))
        XCTAssertNil(detector.detect(samples: [], sampleRate: sampleRate))
        XCTAssertNil(detector.detect(samples: signal(440), sampleRate: 0))
        XCTAssertNil(detector.detect(samples: [Float](repeating: .nan, count: 2160), sampleRate: sampleRate))
        var seed: UInt64 = 42
        let noise: [Float] = (0..<2160).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5)
        }
        XCTAssertNil(detector.detect(samples: noise, sampleRate: sampleRate))
    }

    func testRealInputSampleRates() throws {
        for rate in [44100.0, 48000, 96000] {
            let samples = signal(261.625565, rate: rate)
            let strideSize = max(1, Int(rate / 12000))
            let reduced: [Float] = stride(from: 0, through: samples.count - strideSize, by: strideSize).map { index in
                samples[index..<(index + strideSize)].reduce(0, +) / Float(strideSize)
            }
            let reading = try XCTUnwrap(detector.detect(samples: reduced, sampleRate: rate / Double(strideSize)))
            XCTAssertEqual(reading.note.midi, 60)
            XCTAssertEqual(reading.cents, 0, accuracy: 2)
        }
    }
}
