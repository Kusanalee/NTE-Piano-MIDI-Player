import Foundation

public enum LayoutMode: String, Codable, CaseIterable, Identifiable {
    case nte21Natural
    case nte36Chromatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nte21Natural: "21-key natural"
        case .nte36Chromatic: "36-key chromatic"
        }
    }
}

public enum NaturalScaleHandling: String, Codable, CaseIterable, Identifiable {
    case skipUnplayable
    case snapToNearest
    case transposeSongToFitCMajor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .skipUnplayable: "Skip unplayable notes"
        case .snapToNearest: "Snap to nearest playable note"
        case .transposeSongToFitCMajor: "Transpose song to C major"
        }
    }
}

public enum AutoFitMode: String, Codable, CaseIterable, Identifiable {
    case off
    case shiftOctaveIntoRange
    case clampOrSkip

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .shiftOctaveIntoRange: "Shift octave into range"
        case .clampOrSkip: "Clamp/skip"
        }
    }
}

public enum MusicalKey: String, Codable, CaseIterable, Identifiable {
    case c = "C"
    case cSharp = "C#"
    case d = "D"
    case eFlat = "Eb"
    case e = "E"
    case f = "F"
    case fSharp = "F#"
    case g = "G"
    case aFlat = "Ab"
    case a = "A"
    case bFlat = "Bb"
    case b = "B"

    public var id: String { rawValue }

    public var semitone: Int {
        switch self {
        case .c: 0
        case .cSharp: 1
        case .d: 2
        case .eFlat: 3
        case .e: 4
        case .f: 5
        case .fSharp: 6
        case .g: 7
        case .aFlat: 8
        case .a: 9
        case .bFlat: 10
        case .b: 11
        }
    }
}

public enum EmergencyStopHotkey: String, Codable, CaseIterable, Identifiable {
    case escape
    case commandPeriod

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .escape: "Escape"
        case .commandPeriod: "Command + ."
        }
    }
}

public enum ThemePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

public struct PlaybackSettings: Codable, Equatable {
    public static let defaultAcceptedForegroundAppNames = ["NTE.app", "NTE", "Neverness to Everness"]

    public var layoutMode: LayoutMode
    public var baseMidiNoteForBAS1: Int
    public var globalTranspose: Int
    public var octaveShift: Int
    public var autoFitMode: AutoFitMode
    public var naturalScaleHandling: NaturalScaleHandling
    public var sourceKey: MusicalKey
    public var targetKey: MusicalKey
    public var keyTranspositionEnabled: Bool
    public var tempoMultiplier: Double
    public var countdownDuration: Double
    public var tapDuration: Double
    public var holdSustainedNotes: Bool
    public var maxHoldDuration: Double
    public var chordThreshold: Double
    public var chordStagger: Double
    public var mergeThreshold: Double
    public var simultaneousKeyLimit: Int
    public var dryRun: Bool
    public var acceptedForegroundAppNames: [String]
    public var emergencyStopHotkey: EmergencyStopHotkey
    public var themePreference: ThemePreference
    public var manualKeyOverrides: [String: KeyboardKey]

    public init(
        layoutMode: LayoutMode = .nte36Chromatic,
        baseMidiNoteForBAS1: Int = 48,
        globalTranspose: Int = 0,
        octaveShift: Int = 0,
        autoFitMode: AutoFitMode = .off,
        naturalScaleHandling: NaturalScaleHandling = .skipUnplayable,
        sourceKey: MusicalKey = .c,
        targetKey: MusicalKey = .c,
        keyTranspositionEnabled: Bool = false,
        tempoMultiplier: Double = 1.0,
        countdownDuration: Double = 3.0,
        tapDuration: Double = 0.032,
        holdSustainedNotes: Bool = false,
        maxHoldDuration: Double = 2.0,
        chordThreshold: Double = 0.010,
        chordStagger: Double = 0.005,
        mergeThreshold: Double = 0.015,
        simultaneousKeyLimit: Int = 6,
        dryRun: Bool = true,
        acceptedForegroundAppNames: [String] = PlaybackSettings.defaultAcceptedForegroundAppNames,
        emergencyStopHotkey: EmergencyStopHotkey = .escape,
        themePreference: ThemePreference = .system,
        manualKeyOverrides: [String: KeyboardKey] = [:]
    ) {
        self.layoutMode = layoutMode
        self.baseMidiNoteForBAS1 = baseMidiNoteForBAS1
        self.globalTranspose = globalTranspose
        self.octaveShift = octaveShift
        self.autoFitMode = autoFitMode
        self.naturalScaleHandling = naturalScaleHandling
        self.sourceKey = sourceKey
        self.targetKey = targetKey
        self.keyTranspositionEnabled = keyTranspositionEnabled
        self.tempoMultiplier = tempoMultiplier
        self.countdownDuration = countdownDuration
        self.tapDuration = tapDuration
        self.holdSustainedNotes = holdSustainedNotes
        self.maxHoldDuration = maxHoldDuration
        self.chordThreshold = chordThreshold
        self.chordStagger = chordStagger
        self.mergeThreshold = mergeThreshold
        self.simultaneousKeyLimit = simultaneousKeyLimit
        self.dryRun = dryRun
        self.acceptedForegroundAppNames = acceptedForegroundAppNames
        self.emergencyStopHotkey = emergencyStopHotkey
        self.themePreference = themePreference
        self.manualKeyOverrides = manualKeyOverrides
    }

    public var midiNoteForMID1: Int { baseMidiNoteForBAS1 + 12 }
    public var midiNoteForTRE1: Int { baseMidiNoteForBAS1 + 24 }

    public var playableRange: ClosedRange<Int> {
        baseMidiNoteForBAS1...(baseMidiNoteForBAS1 + 35)
    }

    public var keyTranspositionSemitones: Int {
        guard keyTranspositionEnabled else { return 0 }
        return targetKey.semitone - sourceKey.semitone
    }

    public func clamped() -> PlaybackSettings {
        var copy = self
        copy.baseMidiNoteForBAS1 = min(max(copy.baseMidiNoteForBAS1, 0), 92)
        copy.globalTranspose = min(max(copy.globalTranspose, -24), 24)
        copy.octaveShift = min(max(copy.octaveShift, -3), 3)
        copy.tempoMultiplier = min(max(copy.tempoMultiplier, 0.25), 2.0)
        copy.countdownDuration = min(max(copy.countdownDuration, 0), 10)
        copy.tapDuration = min(max(copy.tapDuration, 0.005), 0.250)
        copy.maxHoldDuration = min(max(copy.maxHoldDuration, 0.050), 10)
        copy.chordThreshold = min(max(copy.chordThreshold, 0.001), 0.100)
        copy.chordStagger = min(max(copy.chordStagger, 0), 0.050)
        copy.mergeThreshold = min(max(copy.mergeThreshold, 0), 0.100)
        copy.simultaneousKeyLimit = min(max(copy.simultaneousKeyLimit, 1), 12)
        copy.acceptedForegroundAppNames = copy.acceptedForegroundAppNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if copy.acceptedForegroundAppNames.isEmpty {
            copy.acceptedForegroundAppNames = Self.defaultAcceptedForegroundAppNames
        } else {
            for appName in Self.defaultAcceptedForegroundAppNames where !copy.acceptedForegroundAppNames.caseInsensitiveContains(appName) {
                copy.acceptedForegroundAppNames.append(appName)
            }
        }
        return copy
    }
}

private extension Array where Element == String {
    func caseInsensitiveContains(_ candidate: String) -> Bool {
        contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }
}
