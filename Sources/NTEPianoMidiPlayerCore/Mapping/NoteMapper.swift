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
        for event in events.sorted(by: {
            if $0.startTime == $1.startTime {
                return $0.midiNote < $1.midiNote
            }
            return $0.startTime < $1.startTime
        }) {
            guard let adjustedNote = adjustedMidiNote(for: event, settings: settings, diagnostics: &diagnostics) else {
                continue
            }
            guard let pianoKey = pianoKey(for: adjustedNote, settings: settings, diagnostics: &diagnostics) else {
                continue
            }
            mapped.append(
                MappedNoteEvent(
                    source: event,
                    adjustedMidiNote: adjustedNote,
                    pianoKey: pianoKey,
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

    private func adjustedMidiNote(
        for event: MidiNoteEvent,
        settings: PlaybackSettings,
        diagnostics: inout MappingDiagnostics
    ) -> Int? {
        var note = Int(event.midiNote) + settings.globalTranspose + (settings.octaveShift * 12)

        if layoutMode == .nte21Natural, settings.naturalScaleHandling == .transposeSongToFitCMajor {
            guard let transposed = majorScaleTransposition(
                midiNote: note,
                sourceKey: settings.sourceKey,
                targetKey: .c
            ) else {
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
    ) -> Int? {
        let range = settings.playableRange
        guard !range.contains(note) else { return note }

        if note < range.lowerBound {
            diagnostics.notesBelowRange += 1
        } else {
            diagnostics.notesAboveRange += 1
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
                return shifted
            }
            diagnostics.notesSkipped += 1
            return nil
        case .clampOrSkip:
            return min(max(note, range.lowerBound), range.upperBound)
        }
    }

    private func pianoKey(
        for adjustedNote: Int,
        settings: PlaybackSettings,
        diagnostics: inout MappingDiagnostics
    ) -> PianoKey? {
        guard NTELayout.row(for: adjustedNote, baseMidiNote: settings.baseMidiNoteForBAS1) != nil else {
            diagnostics.notesSkipped += 1
            return nil
        }

        var note = adjustedNote
        var semitone = positiveModulo(note - settings.baseMidiNoteForBAS1, 12)

        if layoutMode == .nte21Natural, !NTELayout.naturalSemitones.contains(semitone) {
            switch settings.naturalScaleHandling {
            case .skipUnplayable, .transposeSongToFitCMajor:
                diagnostics.notesSkipped += 1
                return nil
            case .snapToNearest:
                note = snapToNearestNatural(
                    note,
                    baseMidiNote: settings.baseMidiNoteForBAS1,
                    range: settings.playableRange
                )
                semitone = positiveModulo(note - settings.baseMidiNoteForBAS1, 12)
                diagnostics.notesSnapped += 1
            }
        }

        guard let rowAfterSnap = NTELayout.row(for: note, baseMidiNote: settings.baseMidiNoteForBAS1) else {
            diagnostics.notesSkipped += 1
            return nil
        }

        switch layoutMode {
        case .nte21Natural:
            guard let naturalIndex = NTELayout.naturalSemitones.firstIndex(of: semitone),
                  let keys = NTELayout.rowKeys[rowAfterSnap] else {
                diagnostics.notesSkipped += 1
                return nil
            }
            let key = manualOverride(
                row: rowAfterSnap,
                semitone: semitone,
                settings: settings
            ) ?? keys[naturalIndex]
            return PianoKey(
                row: rowAfterSnap,
                semitone: semitone,
                degreeLabel: NTELayout.naturalDegreeLabels[naturalIndex],
                noteName: NTELayout.noteNames[semitone],
                keyboardKey: key,
                modifier: .none,
                midiNote: note
            )
        case .nte36Chromatic:
            guard let entry = NTELayout.chromaticDegreeMap[semitone],
                  let keys = NTELayout.rowKeys[rowAfterSnap] else {
                diagnostics.notesSkipped += 1
                return nil
            }
            let key = manualOverride(
                row: rowAfterSnap,
                semitone: semitone,
                settings: settings
            ) ?? keys[entry.naturalIndex]
            return PianoKey(
                row: rowAfterSnap,
                semitone: semitone,
                degreeLabel: entry.degree,
                noteName: NTELayout.noteNames[semitone],
                keyboardKey: key,
                modifier: entry.modifier,
                midiNote: note
            )
        }
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
        let majorScale = NTELayout.naturalSemitones
        let sourceRelative = positiveModulo(midiNote - sourceKey.semitone, 12)
        guard majorScale.contains(sourceRelative) else {
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
            let signature = "\(event.pianoKey.row.rawValue)-\(event.pianoKey.keyboardKey.rawValue)-\(event.pianoKey.modifier.rawValue)"
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
                groupSize += 1
            } else {
                if groupSize > limit { count += 1 }
                groupStart = event.startTime
                groupSize = 1
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
