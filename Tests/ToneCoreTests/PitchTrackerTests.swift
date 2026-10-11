import Foundation
import XCTest
@testable import ToneCore

final class PitchTrackerTests: XCTestCase {
    private func reading(_ midi: Double, confidence: Double = 1) -> PitchReading {
        PitchReading(frequency: 440 * pow(2, (midi - 69) / 12), confidence: confidence)!
    }
    private func feed(_ tracker: inout PitchTracker, midi: Double, count: Int = 3, from time: Double = 0) {
        for i in 0..<count { tracker.process(reading(midi), level: 0.01, at: time + Double(i) * 0.08) }
    }

    func testAcquisitionWithinHalfSecondForBothProfiles() {
        for profile in TrackingProfile.allCases {
            var tracker = PitchTracker(profile: profile)
            for i in 0..<profile.confirmations {
                let display = tracker.process(reading(60), level: 0.001, at: 0.18 + Double(i) * 0.08)
                XCTAssertEqual(display.pitch != nil, i == profile.confirmations - 1)
            }
            XCTAssertEqual(tracker.display.pitch?.note.midi, 60)
            XCTAssertLessThan(tracker.display.time, 0.5)
        }
    }

    func testIsolatedOctaveErrorsDoNotMoveNeedleOrChangeNote() {
        for profile in TrackingProfile.allCases {
            var tracker = PitchTracker(profile: profile)
            feed(&tracker, midi: 57)
            let original = tracker.display.pitch
            for (i, midi) in [69.0, 57, 45, 57].enumerated() {
                let result = tracker.process(reading(midi), level: 0.01, at: 0.24 + Double(i) * 0.08)
                XCTAssertEqual(result.pitch, original)
            }
        }
    }

    func testRealOctaveChangeResetsSmoothingAndHistory() {
        for profile in TrackingProfile.allCases {
            var tracker = PitchTracker(profile: profile)
            feed(&tracker, midi: 57)
            feed(&tracker, midi: 69.2, count: profile.confirmations, from: 0.24)
            XCTAssertEqual(tracker.display.pitch?.note.midi, 69)
            XCTAssertEqual(tracker.display.pitch!.cents, 20, accuracy: 0.0001)
            XCTAssertEqual(tracker.display.history.count, 1)
        }
    }

    func testBoundaryHysteresisAndConsistentCents() {
        for profile in TrackingProfile.allCases {
            var tracker = PitchTracker(profile: profile)
            feed(&tracker, midi: 60)
            for i in 0..<30 {
                let result = tracker.process(reading(i.isMultiple(of: 2) ? 60.49 : 60.51),
                                             level: 0.01, at: 0.24 + Double(i) * 0.08)
                XCTAssertEqual(result.pitch?.note.midi, 60)
                let pitch = result.pitch!
                XCTAssertEqual(1200 * log2(pitch.frequency / pitch.note.frequency()), pitch.cents, accuracy: 1e-8)
            }
            feed(&tracker, midi: 60.7, count: profile.confirmations, from: 2.64)
            XCTAssertEqual(tracker.display.pitch?.note.midi, 61)
            XCTAssertEqual(tracker.display.pitch!.cents, -30, accuracy: 0.0001)
        }
    }

    func testVibratoIsDampedButVisibleInRawHistory() {
        for profile in TrackingProfile.allCases {
            var tracker = PitchTracker(profile: profile)
            feed(&tracker, midi: 69)
            var excursions: [Double] = []
            for i in 0..<40 {
                let time = 0.24 + Double(i) * 0.08
                let midi = 69 + 0.25 * sin(2 * .pi * 5 * time)
                tracker.process(reading(midi), level: 0.01, at: time)
                XCTAssertEqual(tracker.display.pitch?.note.midi, 69)
                excursions.append(abs(tracker.display.pitch!.cents))
            }
            XCTAssertLessThan(excursions.max()!, 15)
            XCTAssertGreaterThan(tracker.display.history.map { abs($0.cents) }.max()!, 20)
            XCTAssertTrue(tracker.display.history.allSatisfy { tracker.display.time - $0.time <= 3 })
        }
    }

    func testAttackErrorAndGlissandoDoNotLockWrongOctave() {
        var tracker = PitchTracker()
        tracker.process(reading(81), level: 0.01, at: 0)
        feed(&tracker, midi: 69, from: 0.08)
        XCTAssertEqual(tracker.display.pitch?.note.midi, 69)
        for i in 0..<61 {
            tracker.process(reading(69 + Double(i) * 0.05), level: 0.01, at: 0.32 + Double(i) * 0.08)
        }
        feed(&tracker, midi: 72, count: 15, from: 5.28)
        XCTAssertEqual(tracker.display.pitch?.note.midi, 72)
        XCTAssertEqual(tracker.display.pitch!.cents, 0, accuracy: 1)
    }

    func testSustainedDetuningRemainsVisible() {
        for cents in [-30.0, 30] {
            var tracker = PitchTracker()
            feed(&tracker, midi: 69)
            feed(&tracker, midi: 69 + cents / 100, count: 30, from: 0.24)
            XCTAssertEqual(tracker.display.pitch!.cents, cents, accuracy: 0.1)
        }
    }

    func testConfidenceSilenceAndTimedDropoutWithoutCallbacks() {
        var tracker = PitchTracker()
        feed(&tracker, midi: 69)
        let stable = tracker.display.pitch
        tracker.process(reading(81, confidence: 0.74), level: 0.02, at: 0.24)
        XCTAssertEqual(tracker.display.state, .unstable)
        XCTAssertEqual(tracker.display.pitch, stable)
        XCTAssertTrue(tracker.display.needleVisible)
        tracker.advance(to: 0.461)
        XCTAssertEqual(tracker.display.state, .holding)
        XCTAssertFalse(tracker.display.needleVisible)
        XCTAssertEqual(tracker.display.pitch, stable)
        tracker.advance(to: 1.161)
        XCTAssertNil(tracker.display.pitch)
        XCTAssertEqual(tracker.display.state, .searching)
        for i in 0..<4 { tracker.process(reading(69), level: 0.0001, at: 1.2 + Double(i) * 0.08) }
        XCTAssertNil(tracker.display.pitch)
        for i in 0..<4 { tracker.process(reading(69, confidence: 0.79), level: 0.01, at: 1.6 + Double(i) * 0.08) }
        XCTAssertNil(tracker.display.pitch)
    }

    func testShortGapRecoversAndBreaksHistorySegment() {
        var tracker = PitchTracker()
        feed(&tracker, midi: 69)
        tracker.process(nil, level: 0, at: 0.24)
        tracker.process(nil, level: 0, at: 0.32)
        tracker.process(reading(69), level: 0.01, at: 0.40)
        XCTAssertEqual(tracker.display.state, .tracking)
        XCTAssertTrue(tracker.display.needleVisible)
        XCTAssertGreaterThan(tracker.display.history.last!.time - tracker.display.history.dropLast().last!.time, 0.18)
    }

    func testOutOfOrderAndInvalidClockDoNotCorruptDisplay() {
        var tracker = PitchTracker()
        feed(&tracker, midi: 60)
        let display = tracker.display
        XCTAssertEqual(tracker.process(reading(81), level: 0.01, at: -1), display)
        XCTAssertEqual(tracker.advance(to: .nan), display)
    }

    func testQuietLowHarmonicVoiceWithNoiseThroughCapturePipeline() throws {
        let rate = 48000.0
        for fundamental in [82.407, 110, 220, 440, 493.883] {
            var phase = 0.0
            var seed: UInt64 = 42
            var input = PitchInputWindow(sampleRate: rate)
            var tracker = PitchTracker()
            let detector = PitchDetector()
            var chunk: [Float] = []
            var firstStableTime: Double?
            for index in 0..<Int(rate * 1.2) {
                let time = Double(index) / rate
                let frequency = fundamental * pow(2, 20 * sin(2 * .pi * 5 * time) / 1200)
                phase += 2 * .pi * frequency / rate
                seed = seed &* 6364136223846793005 &+ 1
                let noise = (Double(seed >> 32) / Double(UInt32.max) - 0.5) * 0.0005
                chunk.append(Float(0.002 * (0.5 * sin(phase) + sin(2 * phase) + 0.3 * sin(3 * phase)) + noise))
                if chunk.count == 2048 {
                    if let window = input.append(chunk) {
                        let reduced = PitchInputWindow.downsample(window, sampleRate: rate)
                        let reading = detector.detect(samples: reduced.samples, sampleRate: reduced.rate)
                        tracker.process(reading, level: 0.002, at: time)
                        if tracker.display.state == .tracking, firstStableTime == nil { firstStableTime = time }
                    }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            XCTAssertLessThan(try XCTUnwrap(firstStableTime), 0.5, "\(fundamental) Hz")
            let display = try XCTUnwrap(tracker.display.pitch, "\(fundamental) Hz")
            XCTAssertEqual(display.note, PitchReading(frequency: fundamental)!.note)
            XCTAssertLessThan(abs(display.cents), 15)
        }
    }

    func testBroadbandNoiseDoesNotEstablishNote() {
        var tracker = PitchTracker()
        var seed: UInt64 = 1
        let detector = PitchDetector()
        for frame in 0..<10 {
            let samples: [Float] = (0..<2160).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5)
            }
            tracker.process(detector.detect(samples: samples, sampleRate: 12000), level: 0.1, at: Double(frame) * 0.08)
        }
        XCTAssertNil(tracker.display.pitch)
    }

    func testLifecycleDesiredStateDuringPermissionAndPageChanges() {
        var activity = AudioActivity()
        XCTAssertEqual(activity.target, .off)
        activity.isActive = true
        XCTAssertEqual(activity.target, .tuner)
        activity.isTuner = false // permission response must not start capture on the pad
        XCTAssertEqual(activity.target, .reference)
        activity.isTuner = true
        XCTAssertEqual(activity.target, .tuner)
        activity.isActive = false
        XCTAssertEqual(activity.target, .off)
        activity.isActive = true
        XCTAssertEqual(activity.target, .tuner)
    }

    func testInterruptionResumesOnlyWhenAllowedAndForeground() {
        var activity = AudioActivity()
        activity.isActive = true
        activity.interruptionBegan()
        XCTAssertEqual(activity.target, .off)
        activity.interruptionEnded(canResume: true)
        XCTAssertEqual(activity.target, .tuner)
        activity.interruptionBegan()
        activity.isActive = false
        activity.interruptionEnded(canResume: true)
        XCTAssertEqual(activity.target, .off)
        activity.isActive = true
        activity.interruptionBegan()
        activity.interruptionEnded(canResume: false)
        XCTAssertEqual(activity.target, .off)
        activity.retry()
        XCTAssertEqual(activity.target, .tuner)
        activity.isTuner = false
        activity.interruptionBegan()
        activity.interruptionEnded(canResume: true)
        XCTAssertEqual(activity.target, .reference)
    }
}
