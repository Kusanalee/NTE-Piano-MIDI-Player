import Foundation

public struct MidiNoteEvent: Codable, Equatable, Identifiable {
    public var id: UUID
    public var midiNote: UInt8
    public var velocity: UInt8
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var channel: UInt8
    public var trackIndex: Int

    public init(
        id: UUID = UUID(),
        midiNote: UInt8,
        velocity: UInt8,
        startTime: TimeInterval,
        duration: TimeInterval,
        channel: UInt8,
        trackIndex: Int
    ) {
        self.id = id
        self.midiNote = midiNote
        self.velocity = velocity
        self.startTime = startTime
        self.duration = duration
        self.channel = channel
        self.trackIndex = trackIndex
    }
}

public struct MidiTrackInfo: Codable, Equatable, Identifiable {
    public var id: Int { trackIndex }
    public var trackIndex: Int
    public var name: String
    public var channel: UInt8?
    public var instrumentProgram: UInt8?
    public var instrumentName: String?
    public var noteCount: Int
    public var isEnabled: Bool
    public var isMuted: Bool
    public var isSoloed: Bool

    public init(
        trackIndex: Int,
        name: String,
        channel: UInt8?,
        instrumentProgram: UInt8?,
        instrumentName: String?,
        noteCount: Int,
        isEnabled: Bool = true,
        isMuted: Bool = false,
        isSoloed: Bool = false
    ) {
        self.trackIndex = trackIndex
        self.name = name
        self.channel = channel
        self.instrumentProgram = instrumentProgram
        self.instrumentName = instrumentName
        self.noteCount = noteCount
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

public struct MidiTempoChange: Codable, Equatable {
    public var beat: Double
    public var seconds: TimeInterval
    public var bpm: Double

    public init(beat: Double, seconds: TimeInterval, bpm: Double) {
        self.beat = beat
        self.seconds = seconds
        self.bpm = bpm
    }
}

public struct MidiTimeSignature: Codable, Equatable {
    public var beat: Double
    public var numerator: Int
    public var denominator: Int

    public init(beat: Double, numerator: Int, denominator: Int) {
        self.beat = beat
        self.numerator = numerator
        self.denominator = denominator
    }
}

public struct MidiDocument: Codable, Equatable {
    public var url: URL
    public var displayName: String
    public var tracks: [MidiTrackInfo]
    public var noteEvents: [MidiNoteEvent]
    public var tempoChanges: [MidiTempoChange]
    public var timeSignatures: [MidiTimeSignature]
    public var duration: TimeInterval

    public init(
        url: URL,
        displayName: String,
        tracks: [MidiTrackInfo],
        noteEvents: [MidiNoteEvent],
        tempoChanges: [MidiTempoChange],
        timeSignatures: [MidiTimeSignature],
        duration: TimeInterval
    ) {
        self.url = url
        self.displayName = displayName
        self.tracks = tracks
        self.noteEvents = noteEvents
        self.tempoChanges = tempoChanges
        self.timeSignatures = timeSignatures
        self.duration = duration
    }
}
