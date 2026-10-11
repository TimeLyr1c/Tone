import Foundation

enum TrackingProfile: String, CaseIterable, Identifiable {
    case voice, instrument
    var id: String { rawValue }
    var title: String { self == .voice ? "人声" : "乐器" }
    var medianCount: Int { self == .voice ? 5 : 3 }
    var timeConstant: Double { self == .voice ? 0.25 : 0.08 }
    var confirmations: Int { self == .voice ? 3 : 2 }
    var boundaryMargin: Double { self == .voice ? 0.10 : 0.05 }
    var tolerance: Double { self == .voice ? 15 : 5 }
}

struct DisplayPitch: Equatable {
    let note: MusicalNote
    let frequency: Double
    let cents: Double
}

struct PitchHistoryPoint: Equatable {
    let time: Double
    let cents: Double
}

enum PitchTrackingState: Equatable {
    case searching, tracking, unstable, holding
}

struct PitchDisplay: Equatable {
    var pitch: DisplayPitch?
    var state: PitchTrackingState = .searching
    var needleVisible = false
    var history: [PitchHistoryPoint] = []
    var time = 0.0
    var status = "等待声音"
}

/// Works in continuous MIDI (log frequency), never averages cents across note boundaries.
/// Clock and readings are injected so dropout, octave jumps and latency are deterministic.
struct PitchTracker {
    let profile: TrackingProfile
    private(set) var display = PitchDisplay()
    private var lockedNote: Int?
    private var pendingNote: Int?
    private var pendingPitches: [Double] = []
    private var pitches: [Double] = []
    private var smoothedMIDI: Double?
    private var lastAccepted: Double?
    private var lastInput: Double?
    private var lastClock = -Double.infinity

    init(profile: TrackingProfile = .voice) { self.profile = profile }

    @discardableResult
    mutating func process(_ reading: PitchReading?, level: Double, at time: Double) -> PitchDisplay {
        guard time.isFinite, time >= lastClock else { return display }
        advance(to: time)
        lastInput = time
        let threshold = lockedNote == nil ? 0.80 : 0.75
        guard let reading, reading.confidence >= threshold, level.isFinite, level >= 0.0005 else {
            pendingNote = nil
            pendingPitches.removeAll()
            markUnreliable(level: level)
            return display
        }
        let midi = 69 + 12 * log2(reading.frequency / 440)
        let needsNewNote = lockedNote.map { abs(midi - Double($0)) > 0.5 + profile.boundaryMargin } ?? true
        if needsNewNote {
            let candidate = Int(midi.rounded())
            // A sequence must agree in note AND pitch, rather than merely remain far from the old note.
            if pendingNote != candidate || pendingPitches.last.map({ abs($0 - midi) > 0.4 }) == true {
                pendingNote = candidate
                pendingPitches = []
            }
            pendingPitches.append(midi)
            guard pendingPitches.count >= profile.confirmations else {
                markUnreliable(level: level)
                return display
            }
            lockedNote = candidate
            pitches = Array(pendingPitches.suffix(profile.medianCount))
            smoothedMIDI = median(pitches)
            display.history.removeAll()
        } else {
            pitches.append(midi)
            pitches = Array(pitches.suffix(profile.medianCount))
            let target = median(pitches)
            let elapsed = max(0, time - (lastAccepted ?? time))
            let alpha = 1 - exp(-elapsed / profile.timeConstant)
            smoothedMIDI = (smoothedMIDI ?? target) + alpha * (target - (smoothedMIDI ?? target))
        }
        pendingNote = nil
        pendingPitches.removeAll()
        lastAccepted = time
        let note = lockedNote!
        let value = smoothedMIDI!
        display.pitch = DisplayPitch(note: MusicalNote(midi: note), frequency: 440 * pow(2, (value - 69) / 12),
                                     cents: (value - Double(note)) * 100)
        display.history.append(PitchHistoryPoint(time: time, cents: (midi - Double(note)) * 100))
        display.state = .tracking
        display.needleVisible = true
        display.status = "已找到音高"
        return display
    }

    @discardableResult
    mutating func advance(to time: Double) -> PitchDisplay {
        guard time.isFinite, time >= lastClock else { return display }
        lastClock = time
        display.time = time
        display.history.removeAll { time - $0.time > 3 }
        if let lastAccepted {
            let age = time - lastAccepted
            if age >= 1 {
                lockedNote = nil
                smoothedMIDI = nil
                pitches.removeAll()
                pendingNote = nil
                pendingPitches.removeAll()
                self.lastAccepted = nil
                display.pitch = nil
                display.history.removeAll()
                display.state = .searching
                display.needleVisible = false
                display.status = "等待声音"
            } else if age >= 0.3 {
                display.state = .holding
                display.needleVisible = false
                display.status = "上次检测"
            } else if let lastInput, time - lastInput >= 0.18 {
                display.state = .unstable
                display.status = "寻找稳定音高"
            }
        }
        return display
    }

    private mutating func markUnreliable(level: Double) {
        if display.pitch == nil {
            display.state = .searching
            display.needleVisible = false
            display.status = level < 0.0005 ? "等待声音，请靠近麦克风" : "寻找稳定音高"
        } else if display.state != .holding {
            display.state = .unstable
            display.status = "寻找稳定音高"
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Desired audio state survives asynchronous permission dialogs and system interruptions.
struct AudioActivity {
    enum Target: Equatable { case off, tuner, reference }
    var isActive = false
    var isTuner = true
    private(set) var interrupted = false
    private(set) var requiresRetry = false
    var target: Target {
        guard isActive, !interrupted, !requiresRetry else { return .off }
        return isTuner ? .tuner : .reference
    }
    mutating func interruptionBegan() { interrupted = true }
    mutating func interruptionEnded(canResume: Bool) {
        interrupted = false
        requiresRetry = !canResume
    }
    mutating func retry() { requiresRetry = false }
}
