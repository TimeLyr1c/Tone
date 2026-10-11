import Foundation

struct MusicalNote: Equatable, Identifiable {
    let midi: Int
    var id: Int { midi }
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    var name: String { Self.names[((midi % 12) + 12) % 12] }
    var octave: Int { Int(floor(Double(midi) / 12)) - 1 }
    var label: String { "\(name)\(octave)" }
    var isAccidental: Bool { [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12) }

    func frequency(referenceA: Double = 440) -> Double {
        referenceA * pow(2, Double(midi - 69) / 12)
    }
}

struct PitchReading: Equatable {
    let frequency: Double
    let confidence: Double
    let note: MusicalNote
    let cents: Double

    init?(frequency: Double, confidence: Double = 1, referenceA: Double = 440) {
        guard frequency.isFinite, frequency > 0,
              referenceA.isFinite, referenceA > 0, confidence.isFinite else { return nil }
        let continuousMIDI = 69 + 12 * log2(frequency / referenceA)
        guard (-128...255).contains(continuousMIDI) else { return nil }
        let midi = Int(continuousMIDI.rounded())
        self.frequency = frequency
        self.confidence = confidence
        note = MusicalNote(midi: midi)
        cents = (continuousMIDI - Double(midi)) * 100
    }
}

/// The role is supplied by the listener, never inferred from a single frequency.
enum SungNoteRole: String, CaseIterable, Identifiable {
    case unknown = "只看音高"
    case tonic = "主音"
    case dominant = "属音"

    var id: String { rawValue }

    func tonicCandidate(from note: MusicalNote) -> MusicalNote? {
        switch self {
        case .unknown: return nil
        case .tonic: return note
        case .dominant: return MusicalNote(midi: note.midi - 7)
        }
    }
}
