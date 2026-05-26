import Foundation

public enum PianoRow: String, Codable, CaseIterable, Identifiable {
    case bas = "BAS"
    case mid = "MID"
    case tre = "TRE"

    public var id: String { rawValue }
}

public enum KeyModifier: String, Codable, CaseIterable, Identifiable {
    case none
    case shift
    case control

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: ""
        case .shift: "Shift"
        case .control: "Ctrl"
        }
    }
}

public enum KeyboardKey: String, Codable, CaseIterable, Identifiable, Hashable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"
    case f = "F"
    case g = "G"
    case h = "H"
    case j = "J"
    case m = "M"
    case n = "N"
    case q = "Q"
    case r = "R"
    case s = "S"
    case t = "T"
    case u = "U"
    case v = "V"
    case w = "W"
    case x = "X"
    case y = "Y"
    case z = "Z"

    public var id: String { rawValue }
}

public struct PianoKey: Codable, Equatable, Hashable, Identifiable {
    public var id: String { "\(row.rawValue)-\(semitone)-\(keyboardKey.rawValue)-\(modifier.rawValue)" }
    public var row: PianoRow
    public var semitone: Int
    public var degreeLabel: String
    public var noteName: String
    public var keyboardKey: KeyboardKey
    public var modifier: KeyModifier
    public var midiNote: Int

    public init(
        row: PianoRow,
        semitone: Int,
        degreeLabel: String,
        noteName: String,
        keyboardKey: KeyboardKey,
        modifier: KeyModifier,
        midiNote: Int
    ) {
        self.row = row
        self.semitone = semitone
        self.degreeLabel = degreeLabel
        self.noteName = noteName
        self.keyboardKey = keyboardKey
        self.modifier = modifier
        self.midiNote = midiNote
    }

    public var keyboardLabel: String {
        switch modifier {
        case .none:
            keyboardKey.rawValue
        case .shift:
            "Shift+\(keyboardKey.rawValue)"
        case .control:
            "Ctrl+\(keyboardKey.rawValue)"
        }
    }
}

public struct MappedNoteEvent: Codable, Equatable, Identifiable {
    public var id: UUID
    public var source: MidiNoteEvent
    public var adjustedMidiNote: Int
    public var pianoKey: PianoKey
    public var startTime: TimeInterval
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        source: MidiNoteEvent,
        adjustedMidiNote: Int,
        pianoKey: PianoKey,
        startTime: TimeInterval,
        duration: TimeInterval
    ) {
        self.id = id
        self.source = source
        self.adjustedMidiNote = adjustedMidiNote
        self.pianoKey = pianoKey
        self.startTime = startTime
        self.duration = duration
    }
}

public struct MappingDiagnostics: Codable, Equatable {
    public var totalInputNotes: Int = 0
    public var mappedNotes: Int = 0
    public var notesBelowRange: Int = 0
    public var notesAboveRange: Int = 0
    public var notesSkipped: Int = 0
    public var notesSnapped: Int = 0
    public var duplicateNotesMerged: Int = 0
    public var chordsExceedingLimit: Int = 0
    public var warnings: [String] = []

    public init() {}

    public var hasWarnings: Bool {
        notesBelowRange > 0 ||
            notesAboveRange > 0 ||
            notesSkipped > 0 ||
            notesSnapped > 0 ||
            duplicateNotesMerged > 0 ||
            chordsExceedingLimit > 0 ||
            !warnings.isEmpty
    }
}

public struct NoteMapperResult: Codable, Equatable {
    public var mappedEvents: [MappedNoteEvent]
    public var diagnostics: MappingDiagnostics

    public init(mappedEvents: [MappedNoteEvent], diagnostics: MappingDiagnostics) {
        self.mappedEvents = mappedEvents
        self.diagnostics = diagnostics
    }
}
