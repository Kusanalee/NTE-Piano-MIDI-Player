import Foundation

public protocol NoteMapper {
    func map(events: [MidiNoteEvent], settings: PlaybackSettings) -> NoteMapperResult
}

public struct NTE21NaturalMapper: NoteMapper {
    public init() {}

    public func map(events: [MidiNoteEvent], settings: PlaybackSettings) -> NoteMapperResult {
        MappingPipeline(layoutMode: .nte21Natural).map(events: events, settings: settings)
    }
}

public struct NTE36ChromaticMapper: NoteMapper {
    public init() {}

    public func map(events: [MidiNoteEvent], settings: PlaybackSettings) -> NoteMapperResult {
        MappingPipeline(layoutMode: .nte36Chromatic).map(events: events, settings: settings)
    }
}

public enum NoteMapperFactory {
    public static func mapper(for layoutMode: LayoutMode) -> NoteMapper {
        switch layoutMode {
        case .nte21Natural: NTE21NaturalMapper()
        case .nte36Chromatic: NTE36ChromaticMapper()
        }
    }
}

private struct MappingPipeline {
    let layoutMode: LayoutMode

    func map(events: [MidiNoteEvent], settings rawSettings: PlaybackSettings) -> NoteMapperResult {
        let settings = rawSettings.clamped()
        var diagnostics = MappingDiagnostics()
        diagnostics.totalInputNotes = events.count

        var mapped: [MappedNoteEvent] = []
        for event in sorted(events) {
            guard let adjusted = adjustedMidiNote(for: event, settings: settings, diagnostics: &diagnostics),
                  let mapping = pianoKeys(for: adjusted.note, settings: settings, rangeFolded: adjusted.rangeFolded, diagnostics: &diagnostics) else {
                continue
            }

            mapped.append(
                MappedNoteEvent(
                    source: event,
                    adjustedMidiNote: adjusted.note,
                    pianoKeys: mapping.keys,
                    mappingKind: mapping.kind,
                    wasRangeFolded: adjusted.rangeFolded,
                    startTime: event.startTime,
                    duration: event.duration
                )
            )
        }

        mapped = mergeNearbyDuplicates(mapped, threshold: settings.mergeThreshold, diagnostics: &diagnostics)
        diagnostics.mappedNotes = mapped.count
        diagnostics.chordsExceedingLimit = countChordsExceedingLimit(
            mapped,
            threshold: settings.chordThreshold,
            limit: settings.simultaneousKeyLimit
        )
        diagnostics.warnings = warnings(from: diagnostics)
        return NoteMapperResult(mappedEvents: mapped, diagnostics: diagnostics)
    }

    private struct AdjustedNote {
        var note: Int
        var rangeFolded: Bool
    }

    private struct KeyMapping {
        var keys: [PianoKey]
        var kind: MappingKind
    }

    private func sorted(_ events: [MidiNoteEvent]) -> [MidiNoteEvent] {
        events.sorted {
            if $0.startTime == $1.startTime {
                return $0.midiNote < $1.midiNote
            }
            return $0.startTime < $1.startTime
        }
    }

    private func adjustedMidiNote(
        for event: MidiNoteEvent,
        settings: PlaybackSettings,
        diagnostics: inout MappingDiagnostics
    ) -> AdjustedNote? {
        var note = Int(event.midiNote) + settings.globalTranspose + (settings.octaveShift * 12)

        if layoutMode == .nte21Natural, settings.naturalScaleHandling == .transposeSongToFitCMajor {
            guard let transposed = majorScaleTransposition(midiNote: note, sourceKey: settings.sourceKey, targetKey: .c) else {
                diagnostics.notesSkipped += 1
                return nil
            }
            note = transposed
        } else if settings.keyTranspositionEnabled {
            note += settings.keyTranspositionSemitones
        }

        return fitIntoRange(note, settings: settings, diagnostics: &diagnostics)
    }

    private func fitIntoRange(
        _ note: Int,
        settings: PlaybackSettings,
        diagnostics: inout MappingDiagnostics
    ) -> AdjustedNote? {
        let range = settings.playableRange
        guard !range.contains(note) else {
            return AdjustedNote(note: note, rangeFolded: false)
        }

        if note < range.lowerBound {
            diagnostics.notesBelowRange += 1
        } else {
            diagnostics.notesAboveRange += 1
        }

        if settings.multiKeyApproximationEnabled {
            var folded = note
            while folded < range.lowerBound { folded += 12 }
            while folded > range.upperBound { folded -= 12 }
            if range.contains(folded) {
                diagnostics.notesRangeFolded += 1
                return AdjustedNote(note: folded, rangeFolded: true)
            }
        }

        switch settings.autoFitMode {
        case .off:
            diagnostics.notesSkipped += 1
            return nil
        case .shiftOctaveIntoRange:
            var shifted = note
            while shifted < range.lowerBound { shifted += 12 }
            while shifted > range.upperBound { shifted -= 12 }
            if range.contains(shifted) {
                return AdjustedNote(note: shifted, rangeFolded: false)
            }
            diagnostics.notesSkipped += 1
            return nil
        case .clampOrSkip:
            return AdjustedNote(note: min(max(note, range.lowerBound), range.upperBound), rangeFolded: false)
        }
    }

    private func pianoKeys(
        for adjustedNote: Int,
        settings: PlaybackSettings,
        rangeFolded: Bool,
        diagnostics: inout MappingDiagnostics
    ) -> KeyMapping? {
        guard let row = NTELayout.row(for: adjustedNote, baseMidiNote: settings.baseMidiNoteForBAS1) else {
            diagnostics.notesSkipped += 1
            return nil
        }

        let semitone = positiveModulo(adjustedNote - settings.baseMidiNoteForBAS1, 12)
        if NTELayout.naturalSemitones.contains(semitone) {
            guard var key = naturalKey(for: adjustedNote, row: row, semitone: semitone, settings: settings) else {
                diagnostics.notesSkipped += 1
                return nil
            }
            var keys = [key]
            if rangeFolded, settings.maxApproximationKeys >= 3,
               let color = rangeColorKey(for: adjustedNote, primaryKeys: keys, settings: settings) {
                keys.append(color)
                diagnostics.multiKeyExpandedNotes += 1
            }
            key = keys[0]
            return KeyMapping(keys: keys, kind: rangeFolded ? .rangeFolded : .exact)
        }

        if shouldApproximateAccidental(settings: settings) {
            guard var keys = neighborApproximationKeys(for: adjustedNote, row: row, semitone: semitone, settings: settings) else {
                diagnostics.notesSkipped += 1
                return nil
            }
            if rangeFolded, settings.maxApproximationKeys >= 3,
               let color = rangeColorKey(for: adjustedNote, primaryKeys: keys, settings: settings) {
                keys.append(color)
            }
            diagnostics.notesApproximated += 1
            if keys.count > 1 {
                diagnostics.multiKeyExpandedNotes += 1
            }
            return KeyMapping(keys: keys, kind: rangeFolded ? .rangeFolded : .neighborApproximation)
        }

        switch layoutMode {
        case .nte21Natural:
            switch settings.naturalScaleHandling {
            case .skipUnplayable, .transposeSongToFitCMajor:
                diagnostics.notesSkipped += 1
                return nil
            case .snapToNearest:
                let snapped = snapToNearestNatural(adjustedNote, baseMidiNote: settings.baseMidiNoteForBAS1, range: settings.playableRange)
                let snappedSemitone = positiveModulo(snapped - settings.baseMidiNoteForBAS1, 12)
                guard let snappedRow = NTELayout.row(for: snapped, baseMidiNote: settings.baseMidiNoteForBAS1),
                      let key = naturalKey(for: snapped, row: snappedRow, semitone: snappedSemitone, settings: settings) else {
                    diagnostics.notesSkipped += 1
                    return nil
                }
                diagnostics.notesSnapped += 1
                return KeyMapping(keys: [key], kind: .snapped)
            }
        case .nte36Chromatic:
            guard let key = chromaticModifierKey(for: adjustedNote, row: row, semitone: semitone, settings: settings) else {
                diagnostics.notesSkipped += 1
                return nil
            }
            diagnostics.modifierExactNotes += 1
            return KeyMapping(keys: [key], kind: rangeFolded ? .rangeFolded : .modifierExact)
        }
    }

    private func shouldApproximateAccidental(settings: PlaybackSettings) -> Bool {
        settings.multiKeyApproximationEnabled && settings.accidentalPlaybackMode == .approximateWithNeighbors
    }

    private func naturalKey(
        for midiNote: Int,
        row: PianoRow,
        semitone: Int,
        settings: PlaybackSettings
    ) -> PianoKey? {
        guard let naturalIndex = NTELayout.naturalSemitones.firstIndex(of: semitone),
              let keys = NTELayout.rowKeys[row] else {
            return nil
        }
        let keyboardKey = manualOverride(row: row, semitone: semitone, settings: settings) ?? keys[naturalIndex]
        return PianoKey(
            row: row,
            semitone: semitone,
            degreeLabel: NTELayout.naturalDegreeLabels[naturalIndex],
            noteName: NTELayout.noteNames[semitone],
            keyboardKey: keyboardKey,
            modifier: .none,
            midiNote: midiNote
        )
    }

    private func chromaticModifierKey(
        for midiNote: Int,
        row: PianoRow,
        semitone: Int,
        settings: PlaybackSettings
    ) -> PianoKey? {
        guard let entry = NTELayout.chromaticDegreeMap[semitone],
              let keys = NTELayout.rowKeys[row] else {
            return nil
        }
        let keyboardKey = manualOverride(row: row, semitone: semitone, settings: settings) ?? keys[entry.naturalIndex]
        return PianoKey(
            row: row,
            semitone: semitone,
            degreeLabel: entry.degree,
            noteName: NTELayout.noteNames[semitone],
            keyboardKey: keyboardKey,
            modifier: entry.modifier,
            midiNote: midiNote
        )
    }

    private func neighborApproximationKeys(
        for midiNote: Int,
        row: PianoRow,
        semitone: Int,
        settings: PlaybackSettings
    ) -> [PianoKey]? {
        guard let pair = neighborNaturalSemitones(for: semitone),
              let lower = naturalKey(for: midiNote - semitone + pair.lower, row: row, semitone: pair.lower, settings: settings),
              let upper = naturalKey(for: midiNote - semitone + pair.upper, row: row, semitone: pair.upper, settings: settings) else {
            return nil
        }
        return Array([lower, upper].prefix(settings.maxApproximationKeys))
    }

    private func neighborNaturalSemitones(for semitone: Int) -> (lower: Int, upper: Int)? {
        switch semitone {
        case 1: (0, 2)
        case 3: (2, 4)
        case 6: (5, 7)
        case 8: (7, 9)
        case 10: (9, 11)
        default: nil
        }
    }

    private func rangeColorKey(
        for foldedNote: Int,
        primaryKeys: [PianoKey],
        settings: PlaybackSettings
    ) -> PianoKey? {
        for offset in [12, -12] {
            let candidate = foldedNote + offset
            guard settings.playableRange.contains(candidate),
                  let row = NTELayout.row(for: candidate, baseMidiNote: settings.baseMidiNoteForBAS1) else {
                continue
            }
            let semitone = positiveModulo(candidate - settings.baseMidiNoteForBAS1, 12)
            let key: PianoKey?
            if NTELayout.naturalSemitones.contains(semitone) {
                key = naturalKey(for: candidate, row: row, semitone: semitone, settings: settings)
            } else {
                key = neighborApproximationKeys(for: candidate, row: row, semitone: semitone, settings: settings)?.first
            }
            if let key, !primaryKeys.contains(where: { $0.keyboardKey == key.keyboardKey && $0.modifier == key.modifier }) {
                return key
            }
        }
        return nil
    }

    private func manualOverride(row: PianoRow, semitone: Int, settings: PlaybackSettings) -> KeyboardKey? {
        settings.manualKeyOverrides["\(row.rawValue).\(semitone)"]
    }

    private func snapToNearestNatural(_ midiNote: Int, baseMidiNote: Int, range: ClosedRange<Int>) -> Int {
        let candidates = (-2...2).compactMap { delta -> Int? in
            let candidate = midiNote + delta
            guard range.contains(candidate) else { return nil }
            let semitone = positiveModulo(candidate - baseMidiNote, 12)
            return NTELayout.naturalSemitones.contains(semitone) ? candidate : nil
        }
        return candidates.min { lhs, rhs in
            let leftDistance = abs(lhs - midiNote)
            let rightDistance = abs(rhs - midiNote)
            if leftDistance == rightDistance { return lhs < rhs }
            return leftDistance < rightDistance
        } ?? midiNote
    }

    private func majorScaleTransposition(
        midiNote: Int,
        sourceKey: MusicalKey,
        targetKey: MusicalKey
    ) -> Int? {
        let sourceRelative = positiveModulo(midiNote - sourceKey.semitone, 12)
        guard NTELayout.naturalSemitones.contains(sourceRelative) else {
            return nil
        }
        return midiNote + targetKey.semitone - sourceKey.semitone
    }

    private func mergeNearbyDuplicates(
        _ events: [MappedNoteEvent],
        threshold: TimeInterval,
        diagnostics: inout MappingDiagnostics
    ) -> [MappedNoteEvent] {
        guard threshold > 0 else { return events }
        var lastSeen: [String: TimeInterval] = [:]
        var kept: [MappedNoteEvent] = []

        for event in events {
            let signature = event.pianoKeys
                .map { "\($0.row.rawValue)-\($0.keyboardKey.rawValue)-\($0.modifier.rawValue)" }
                .sorted()
                .joined(separator: "|")
            if let last = lastSeen[signature], event.startTime - last <= threshold {
                diagnostics.duplicateNotesMerged += 1
                continue
            }
            lastSeen[signature] = event.startTime
            kept.append(event)
        }
        return kept
    }

    private func countChordsExceedingLimit(
        _ events: [MappedNoteEvent],
        threshold: TimeInterval,
        limit: Int
    ) -> Int {
        guard limit > 0, !events.isEmpty else { return 0 }
        var count = 0
        var groupStart = events[0].startTime
        var groupSize = 0

        for event in events {
            if event.startTime - groupStart <= threshold {
                groupSize += event.pianoKeys.count
            } else {
                if groupSize > limit { count += 1 }
                groupStart = event.startTime
                groupSize = event.pianoKeys.count
            }
        }
        if groupSize > limit { count += 1 }
        return count
    }

    private func warnings(from diagnostics: MappingDiagnostics) -> [String] {
        var warnings: [String] = []
        if diagnostics.notesBelowRange > 0 {
            warnings.append("\(diagnostics.notesBelowRange) notes were below the playable range.")
        }
        if diagnostics.notesAboveRange > 0 {
            warnings.append("\(diagnostics.notesAboveRange) notes were above the playable range.")
        }
        if diagnostics.notesSkipped > 0 {
            warnings.append("\(diagnostics.notesSkipped) notes were skipped.")
        }
        if diagnostics.notesSnapped > 0 {
            warnings.append("\(diagnostics.notesSnapped) notes were snapped to natural notes.")
        }
        if diagnostics.notesApproximated > 0 {
            warnings.append("\(diagnostics.notesApproximated) notes were approximated with neighbor keys.")
        }
        if diagnostics.notesRangeFolded > 0 {
            warnings.append("\(diagnostics.notesRangeFolded) notes were octave-folded into range.")
        }
        if diagnostics.modifierExactNotes > 0 {
            warnings.append("\(diagnostics.modifierExactNotes) notes used Shift/Ctrl modifier mappings.")
        }
        if diagnostics.multiKeyExpandedNotes > 0 {
            warnings.append("\(diagnostics.multiKeyExpandedNotes) notes expanded to multiple keys.")
        }
        if diagnostics.duplicateNotesMerged > 0 {
            warnings.append("\(diagnostics.duplicateNotesMerged) duplicate mapped notes were merged.")
        }
        if diagnostics.chordsExceedingLimit > 0 {
            warnings.append("\(diagnostics.chordsExceedingLimit) chord groups exceed the simultaneous key limit.")
        }
        return warnings
    }

    private func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
