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

public enum NTELayer: String, Codable, CaseIterable, Identifiable {
    case natural
    case sharp
    case flat

    public var id: String { rawValue }

    public var modifier: KeyModifier {
        switch self {
        case .natural: .none
        case .sharp: .shift
        case .flat: .control
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

public enum MappingKind: String, Codable, CaseIterable, Identifiable {
    case exact
    case modifierExact
    case rangeFolded
    case snapped
    case skipped

    public var id: String { rawValue }
}

public struct MappedNoteEvent: Codable, Equatable, Identifiable {
    public var id: UUID
    public var source: MidiNoteEvent
    public var adjustedMidiNote: Int
    public var pianoKeys: [PianoKey]
    public var mappingKind: MappingKind
    public var wasRangeFolded: Bool
    public var startTime: TimeInterval
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        source: MidiNoteEvent,
        adjustedMidiNote: Int,
        pianoKeys: [PianoKey],
        mappingKind: MappingKind,
        wasRangeFolded: Bool = false,
        startTime: TimeInterval,
        duration: TimeInterval
    ) {
        self.id = id
        self.source = source
        self.adjustedMidiNote = adjustedMidiNote
        self.pianoKeys = pianoKeys
        self.mappingKind = mappingKind
        self.wasRangeFolded = wasRangeFolded
        self.startTime = startTime
        self.duration = duration
    }

    public init(
        id: UUID = UUID(),
        source: MidiNoteEvent,
        adjustedMidiNote: Int,
        pianoKey: PianoKey,
        mappingKind: MappingKind = .exact,
        wasRangeFolded: Bool = false,
        startTime: TimeInterval,
        duration: TimeInterval
    ) {
        self.init(
            id: id,
            source: source,
            adjustedMidiNote: adjustedMidiNote,
            pianoKeys: [pianoKey],
            mappingKind: mappingKind,
            wasRangeFolded: wasRangeFolded,
            startTime: startTime,
            duration: duration
        )
    }

    public var pianoKey: PianoKey {
        pianoKeys[0]
    }

    public var keyboardLabel: String {
        pianoKeys.map(\.keyboardLabel).joined(separator: "+")
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
    public var notesRangeFolded: Int = 0
    public var modifierExactNotes: Int = 0
    public var automaticTranspose: Int = 0
    public var percussionNotesOmitted: Int = 0
    public var chordTonesOmitted: Int = 0
    public var collisionNotesMerged: Int = 0
    public var densityNotesMerged: Int = 0
    public var crossLayerChordsRolled: Int = 0
    public var timingConstrainedTonesOmitted: Int = 0
    public var unsupportedExpressionEvents: Int = 0
    public var warnings: [String] = []

    public init() {}

    public var hasWarnings: Bool {
        notesBelowRange > 0 ||
            notesAboveRange > 0 ||
            notesSkipped > 0 ||
            notesSnapped > 0 ||
            duplicateNotesMerged > 0 ||
            chordsExceedingLimit > 0 ||
            notesRangeFolded > 0 ||
            modifierExactNotes > 0 ||
            automaticTranspose != 0 ||
            percussionNotesOmitted > 0 ||
            chordTonesOmitted > 0 ||
            collisionNotesMerged > 0 ||
            densityNotesMerged > 0 ||
            crossLayerChordsRolled > 0 ||
            timingConstrainedTonesOmitted > 0 ||
            unsupportedExpressionEvents > 0 ||
            !warnings.isEmpty
    }
}

public struct NoteMapperResult: Codable, Equatable {
    public var mappedEvents: [MappedNoteEvent]
    public var playableChords: [PlayableChord]
    public var diagnostics: MappingDiagnostics

    public init(mappedEvents: [MappedNoteEvent], playableChords: [PlayableChord] = [], diagnostics: MappingDiagnostics) {
        self.mappedEvents = mappedEvents
        self.playableChords = playableChords
        self.diagnostics = diagnostics
    }
}

public struct PlayableKeyStroke: Codable, Equatable, Identifiable {
    public var id: UUID
    public var key: PianoKey
    public var source: MidiNoteEvent
    public var adjustedMidiNote: Int
    public var mappingKind: MappingKind
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        key: PianoKey,
        source: MidiNoteEvent,
        adjustedMidiNote: Int,
        mappingKind: MappingKind,
        duration: TimeInterval
    ) {
        self.id = id
        self.key = key
        self.source = source
        self.adjustedMidiNote = adjustedMidiNote
        self.mappingKind = mappingKind
        self.duration = duration
    }

    public var mappedEvent: MappedNoteEvent {
        MappedNoteEvent(
            source: source,
            adjustedMidiNote: adjustedMidiNote,
            pianoKey: key,
            mappingKind: mappingKind,
            wasRangeFolded: mappingKind == .rangeFolded,
            startTime: source.startTime,
            duration: duration
        )
    }
}

public struct PlayableChord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var startTime: TimeInterval
    /// A real-time scheduling offset. `startTime` remains the source MIDI onset.
    public var playbackOffset: TimeInterval
    public var layer: NTELayer
    public var strokes: [PlayableKeyStroke]

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        playbackOffset: TimeInterval = 0,
        layer: NTELayer,
        strokes: [PlayableKeyStroke]
    ) {
        self.id = id
        self.startTime = startTime
        self.playbackOffset = playbackOffset
        self.layer = layer
        self.strokes = strokes
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, playbackOffset, layer, strokes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        playbackOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .playbackOffset) ?? 0
        layer = try container.decode(NTELayer.self, forKey: .layer)
        strokes = try container.decode([PlayableKeyStroke].self, forKey: .strokes)
    }
}

public struct ArrangementResult: Codable, Equatable {
    public var playableChords: [PlayableChord]
    public var mappedEvents: [MappedNoteEvent]
    public var diagnostics: MappingDiagnostics
    public var chosenTranspose: Int

    public init(playableChords: [PlayableChord], diagnostics: MappingDiagnostics, chosenTranspose: Int) {
        self.playableChords = playableChords
        self.mappedEvents = playableChords.flatMap { $0.strokes.map(\.mappedEvent) }
        self.diagnostics = diagnostics
        self.chosenTranspose = chosenTranspose
    }
}
