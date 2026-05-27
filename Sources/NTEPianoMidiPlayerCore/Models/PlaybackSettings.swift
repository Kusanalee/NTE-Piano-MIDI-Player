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

public enum AccidentalPlaybackMode: String, Codable, CaseIterable, Identifiable {
    case approximateWithNeighbors
    case useShiftCtrlModifiers

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .approximateWithNeighbors: "Approximate with neighbors"
        case .useShiftCtrlModifiers: "Use Shift/Ctrl modifiers"
        }
    }
}

public enum ModifierInjectionMode: String, Codable, CaseIterable, Identifiable {
    case hardwareStateLeft
    case hybridLeft
    case flagsOnly
    case hardwareStateRight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hardwareStateLeft: "Hardware state left"
        case .hybridLeft: "Hybrid left"
        case .flagsOnly: "Flags only"
        case .hardwareStateRight: "Hardware state right"
        }
    }
}

public enum EventPostTarget: String, Codable, CaseIterable, Identifiable {
    case hidEventTap
    case sessionEventTap
    case frontmostPid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hidEventTap: "HID event tap"
        case .sessionEventTap: "Session event tap"
        case .frontmostPid: "Frontmost app PID"
        }
    }
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
    public var multiKeyApproximationEnabled: Bool
    public var accidentalPlaybackMode: AccidentalPlaybackMode
    public var maxApproximationKeys: Int
    public var modifierInjectionMode: ModifierInjectionMode
    public var modifierLeadTime: Double
    public var modifierReleaseDelay: Double
    public var modifierReuseWindow: Double
    public var eventPostTarget: EventPostTarget

    private enum CodingKeys: String, CodingKey {
        case layoutMode
        case baseMidiNoteForBAS1
        case globalTranspose
        case octaveShift
        case autoFitMode
        case naturalScaleHandling
        case sourceKey
        case targetKey
        case keyTranspositionEnabled
        case tempoMultiplier
        case countdownDuration
        case tapDuration
        case holdSustainedNotes
        case maxHoldDuration
        case chordThreshold
        case chordStagger
        case mergeThreshold
        case simultaneousKeyLimit
        case dryRun
        case acceptedForegroundAppNames
        case emergencyStopHotkey
        case themePreference
        case manualKeyOverrides
        case multiKeyApproximationEnabled
        case accidentalPlaybackMode
        case maxApproximationKeys
        case modifierInjectionMode
        case modifierLeadTime
        case modifierReleaseDelay
        case modifierReuseWindow
        case eventPostTarget
    }

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
        manualKeyOverrides: [String: KeyboardKey] = [:],
        multiKeyApproximationEnabled: Bool = true,
        accidentalPlaybackMode: AccidentalPlaybackMode = .approximateWithNeighbors,
        maxApproximationKeys: Int = 2,
        modifierInjectionMode: ModifierInjectionMode = .hardwareStateLeft,
        modifierLeadTime: Double = 0.120,
        modifierReleaseDelay: Double = 0.008,
        modifierReuseWindow: Double = 0.120,
        eventPostTarget: EventPostTarget = .hidEventTap
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
        self.multiKeyApproximationEnabled = multiKeyApproximationEnabled
        self.accidentalPlaybackMode = accidentalPlaybackMode
        self.maxApproximationKeys = maxApproximationKeys
        self.modifierInjectionMode = modifierInjectionMode
        self.modifierLeadTime = modifierLeadTime
        self.modifierReleaseDelay = modifierReleaseDelay
        self.modifierReuseWindow = modifierReuseWindow
        self.eventPostTarget = eventPostTarget
    }

    public init(from decoder: Decoder) throws {
        let fallback = PlaybackSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            layoutMode: try container.decodeIfPresent(LayoutMode.self, forKey: .layoutMode) ?? fallback.layoutMode,
            baseMidiNoteForBAS1: try container.decodeIfPresent(Int.self, forKey: .baseMidiNoteForBAS1) ?? fallback.baseMidiNoteForBAS1,
            globalTranspose: try container.decodeIfPresent(Int.self, forKey: .globalTranspose) ?? fallback.globalTranspose,
            octaveShift: try container.decodeIfPresent(Int.self, forKey: .octaveShift) ?? fallback.octaveShift,
            autoFitMode: try container.decodeIfPresent(AutoFitMode.self, forKey: .autoFitMode) ?? fallback.autoFitMode,
            naturalScaleHandling: try container.decodeIfPresent(NaturalScaleHandling.self, forKey: .naturalScaleHandling) ?? fallback.naturalScaleHandling,
            sourceKey: try container.decodeIfPresent(MusicalKey.self, forKey: .sourceKey) ?? fallback.sourceKey,
            targetKey: try container.decodeIfPresent(MusicalKey.self, forKey: .targetKey) ?? fallback.targetKey,
            keyTranspositionEnabled: try container.decodeIfPresent(Bool.self, forKey: .keyTranspositionEnabled) ?? fallback.keyTranspositionEnabled,
            tempoMultiplier: try container.decodeIfPresent(Double.self, forKey: .tempoMultiplier) ?? fallback.tempoMultiplier,
            countdownDuration: try container.decodeIfPresent(Double.self, forKey: .countdownDuration) ?? fallback.countdownDuration,
            tapDuration: try container.decodeIfPresent(Double.self, forKey: .tapDuration) ?? fallback.tapDuration,
            holdSustainedNotes: try container.decodeIfPresent(Bool.self, forKey: .holdSustainedNotes) ?? fallback.holdSustainedNotes,
            maxHoldDuration: try container.decodeIfPresent(Double.self, forKey: .maxHoldDuration) ?? fallback.maxHoldDuration,
            chordThreshold: try container.decodeIfPresent(Double.self, forKey: .chordThreshold) ?? fallback.chordThreshold,
            chordStagger: try container.decodeIfPresent(Double.self, forKey: .chordStagger) ?? fallback.chordStagger,
            mergeThreshold: try container.decodeIfPresent(Double.self, forKey: .mergeThreshold) ?? fallback.mergeThreshold,
            simultaneousKeyLimit: try container.decodeIfPresent(Int.self, forKey: .simultaneousKeyLimit) ?? fallback.simultaneousKeyLimit,
            dryRun: try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? fallback.dryRun,
            acceptedForegroundAppNames: try container.decodeIfPresent([String].self, forKey: .acceptedForegroundAppNames) ?? fallback.acceptedForegroundAppNames,
            emergencyStopHotkey: try container.decodeIfPresent(EmergencyStopHotkey.self, forKey: .emergencyStopHotkey) ?? fallback.emergencyStopHotkey,
            themePreference: try container.decodeIfPresent(ThemePreference.self, forKey: .themePreference) ?? fallback.themePreference,
            manualKeyOverrides: try container.decodeIfPresent([String: KeyboardKey].self, forKey: .manualKeyOverrides) ?? fallback.manualKeyOverrides,
            multiKeyApproximationEnabled: try container.decodeIfPresent(Bool.self, forKey: .multiKeyApproximationEnabled) ?? fallback.multiKeyApproximationEnabled,
            accidentalPlaybackMode: try container.decodeIfPresent(AccidentalPlaybackMode.self, forKey: .accidentalPlaybackMode) ?? fallback.accidentalPlaybackMode,
            maxApproximationKeys: try container.decodeIfPresent(Int.self, forKey: .maxApproximationKeys) ?? fallback.maxApproximationKeys,
            modifierInjectionMode: try container.decodeIfPresent(ModifierInjectionMode.self, forKey: .modifierInjectionMode) ?? fallback.modifierInjectionMode,
            modifierLeadTime: try container.decodeIfPresent(Double.self, forKey: .modifierLeadTime) ?? fallback.modifierLeadTime,
            modifierReleaseDelay: try container.decodeIfPresent(Double.self, forKey: .modifierReleaseDelay) ?? fallback.modifierReleaseDelay,
            modifierReuseWindow: try container.decodeIfPresent(Double.self, forKey: .modifierReuseWindow) ?? fallback.modifierReuseWindow,
            eventPostTarget: try container.decodeIfPresent(EventPostTarget.self, forKey: .eventPostTarget) ?? fallback.eventPostTarget
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layoutMode, forKey: .layoutMode)
        try container.encode(baseMidiNoteForBAS1, forKey: .baseMidiNoteForBAS1)
        try container.encode(globalTranspose, forKey: .globalTranspose)
        try container.encode(octaveShift, forKey: .octaveShift)
        try container.encode(autoFitMode, forKey: .autoFitMode)
        try container.encode(naturalScaleHandling, forKey: .naturalScaleHandling)
        try container.encode(sourceKey, forKey: .sourceKey)
        try container.encode(targetKey, forKey: .targetKey)
        try container.encode(keyTranspositionEnabled, forKey: .keyTranspositionEnabled)
        try container.encode(tempoMultiplier, forKey: .tempoMultiplier)
        try container.encode(countdownDuration, forKey: .countdownDuration)
        try container.encode(tapDuration, forKey: .tapDuration)
        try container.encode(holdSustainedNotes, forKey: .holdSustainedNotes)
        try container.encode(maxHoldDuration, forKey: .maxHoldDuration)
        try container.encode(chordThreshold, forKey: .chordThreshold)
        try container.encode(chordStagger, forKey: .chordStagger)
        try container.encode(mergeThreshold, forKey: .mergeThreshold)
        try container.encode(simultaneousKeyLimit, forKey: .simultaneousKeyLimit)
        try container.encode(dryRun, forKey: .dryRun)
        try container.encode(acceptedForegroundAppNames, forKey: .acceptedForegroundAppNames)
        try container.encode(emergencyStopHotkey, forKey: .emergencyStopHotkey)
        try container.encode(themePreference, forKey: .themePreference)
        try container.encode(manualKeyOverrides, forKey: .manualKeyOverrides)
        try container.encode(multiKeyApproximationEnabled, forKey: .multiKeyApproximationEnabled)
        try container.encode(accidentalPlaybackMode, forKey: .accidentalPlaybackMode)
        try container.encode(maxApproximationKeys, forKey: .maxApproximationKeys)
        try container.encode(modifierInjectionMode, forKey: .modifierInjectionMode)
        try container.encode(modifierLeadTime, forKey: .modifierLeadTime)
        try container.encode(modifierReleaseDelay, forKey: .modifierReleaseDelay)
        try container.encode(modifierReuseWindow, forKey: .modifierReuseWindow)
        try container.encode(eventPostTarget, forKey: .eventPostTarget)
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
        copy.maxApproximationKeys = min(max(copy.maxApproximationKeys, 1), 3)
        copy.modifierLeadTime = min(max(copy.modifierLeadTime, 0), 0.500)
        copy.modifierReleaseDelay = min(max(copy.modifierReleaseDelay, 0), 0.100)
        copy.modifierReuseWindow = min(max(copy.modifierReuseWindow, 0), 1.000)
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
