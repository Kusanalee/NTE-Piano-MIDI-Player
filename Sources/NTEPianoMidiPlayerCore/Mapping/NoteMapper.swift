import Foundation

public protocol NoteMapper {
    func map(events: [MidiNoteEvent], settings: PlaybackSettings) -> NoteMapperResult
}

public struct NTE21NaturalMapper: NoteMapper {
    public init() {}

    public func map(events: [MidiNoteEvent], settings: PlaybackSettings) -> NoteMapperResult {
        let result = UniversalMidiArranger(layoutMode: .nte21Natural).arrange(events: events, settings: settings)
        return NoteMapperResult(mappedEvents: result.mappedEvents, playableChords: result.playableChords, diagnostics: result.diagnostics)
    }
}

public struct NTE36ChromaticMapper: NoteMapper {
    public init() {}

    public func map(events: [MidiNoteEvent], settings: PlaybackSettings) -> NoteMapperResult {
        let result = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(events: events, settings: settings)
        return NoteMapperResult(mappedEvents: result.mappedEvents, playableChords: result.playableChords, diagnostics: result.diagnostics)
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

/// A bounded arranger whose work is sorting plus fixed-size candidate evaluation.
/// It never enumerates note subsets, so dense and multi-track MIDI files remain predictable.
public struct UniversalMidiArranger {
    public let layoutMode: LayoutMode

    public init(layoutMode: LayoutMode) {
        self.layoutMode = layoutMode
    }

    public func arrange(
        events: [MidiNoteEvent],
        settings rawSettings: PlaybackSettings,
        isCancelled: () -> Bool = { false }
    ) -> ArrangementResult {
        let settings = rawSettings.clamped()
        var diagnostics = MappingDiagnostics()
        diagnostics.totalInputNotes = events.count

        let filtered: [MidiNoteEvent]
        if settings.arrangementMode == .automatic {
            filtered = events.filter { event in
                if event.channel == 9 {
                    diagnostics.percussionNotesOmitted += 1
                    return false
                }
                return true
            }
        } else {
            filtered = events
        }

        guard !filtered.isEmpty, !isCancelled() else {
            diagnostics.notesSkipped = events.count - diagnostics.percussionNotesOmitted
            diagnostics.warnings = warnings(for: diagnostics)
            return ArrangementResult(playableChords: [], diagnostics: diagnostics, chosenTranspose: 0)
        }

        let manualTranspose = settings.globalTranspose
            + (settings.octaveShift * 12)
            + manualKeyTranspose(settings: settings)
        let automaticTranspose = chooseAutomaticTranspose(events: filtered, manualTranspose: manualTranspose, settings: settings)
        diagnostics.automaticTranspose = automaticTranspose

        var working = prepareNotes(
            filtered,
            manualTranspose: manualTranspose,
            automaticTranspose: automaticTranspose,
            settings: settings,
            diagnostics: &diagnostics,
            isCancelled: isCancelled
        )
        working = mergeDenseRetriggers(working, threshold: settings.mergeThreshold, diagnostics: &diagnostics)

        let groups = group(notes: working, threshold: settings.chordThreshold)
        let simultaneousKeyLimit = effectiveSimultaneousKeyLimit(settings: settings)
        diagnostics.chordsExceedingLimit = groups.reduce(into: 0) { count, group in
            if group.notes.count > simultaneousKeyLimit { count += 1 }
        }
        guard !isCancelled() else {
            diagnostics.warnings = warnings(for: diagnostics)
            return ArrangementResult(playableChords: [], diagnostics: diagnostics, chosenTranspose: automaticTranspose)
        }

        var chords: [PlayableChord] = []
        if layoutMode == .nte36Chromatic, settings.arrangementMode == .automatic {
            var candidates: [[AdaptiveCandidate]] = []
            candidates.reserveCapacity(groups.count)
            for index in groups.indices {
                if index.isMultiple(of: 256), isCancelled() {
                    diagnostics.warnings = warnings(for: diagnostics)
                    return ArrangementResult(
                        playableChords: [],
                        diagnostics: diagnostics,
                        chosenTranspose: automaticTranspose
                    )
                }
                candidates.append(adaptiveCandidates(
                    for: groups[index],
                    nextStartTime: index + 1 < groups.count ? groups[index + 1].startTime : nil,
                    settings: settings
                ))
            }
            let selected = selectAdaptiveSequence(candidates)
            chords.reserveCapacity(selected.reduce(0) { $0 + $1.packets.count })
            for candidate in selected {
                diagnostics.collisionNotesMerged += candidate.collisionCount
                diagnostics.chordTonesOmitted += candidate.omittedCount
                diagnostics.timingConstrainedTonesOmitted += candidate.timingOmittedCount
                diagnostics.notesSkipped += candidate.unplayableCount
                if candidate.packets.count > 1 { diagnostics.crossLayerChordsRolled += 1 }
                for packet in candidate.packets {
                    diagnostics.modifierExactNotes += packet.strokes.filter {
                        $0.key.modifier != .none && $0.mappingKind == .modifierExact
                    }.count
                    chords.append(packet)
                }
            }
        } else {
            let candidates = groups.map { candidateLayers(for: $0, settings: settings) }
            let selected = selectLayerSequence(candidates)
            chords.reserveCapacity(selected.count)
            for candidate in selected {
                diagnostics.notesSnapped += candidate.snappedCount
                diagnostics.collisionNotesMerged += candidate.collisionCount
                diagnostics.chordTonesOmitted += candidate.omittedCount
                diagnostics.notesSkipped += candidate.unplayableCount
                diagnostics.modifierExactNotes += candidate.strokes.filter {
                    $0.key.modifier != .none && $0.mappingKind == .modifierExact
                }.count
                chords.append(PlayableChord(startTime: candidate.startTime, layer: candidate.layer, strokes: candidate.strokes))
            }
        }

        diagnostics.mappedNotes = chords.reduce(0) { $0 + $1.strokes.count }
        diagnostics.duplicateNotesMerged = diagnostics.collisionNotesMerged + diagnostics.densityNotesMerged
        diagnostics.warnings = warnings(for: diagnostics)
        return ArrangementResult(playableChords: chords, diagnostics: diagnostics, chosenTranspose: automaticTranspose)
    }
}

private extension UniversalMidiArranger {
    struct WorkingNote {
        var source: MidiNoteEvent
        /// Source pitch after explicit user transposition, before automatic fitting.
        var referenceMidiNote: Int
        var midiNote: Int
        var wasRangeFolded: Bool
        var wasPreSnapped: Bool

        var weight: Int {
            Int(source.velocity) * 4 + min(200, Int(source.duration * 100)) + 1
        }
    }

    struct WorkingChord {
        var startTime: TimeInterval
        var notes: [WorkingNote]
    }

    struct CandidateStroke {
        var working: WorkingNote
        var targetNote: Int
        var key: PianoKey
        var layer: NTELayer
        var exactInLayer: Bool
        var priority: Int
    }

    struct LayerCandidate {
        var startTime: TimeInterval
        var layer: NTELayer
        var strokes: [PlayableKeyStroke]
        var score: Int
        var snappedCount: Int
        var collisionCount: Int
        var omittedCount: Int
        var unplayableCount: Int
    }

    struct TransposeScore: Comparable {
        var exactWeight: Int
        var inRangeWeight: Int
        var movementPenalty: Int
        var absoluteTransposePenalty: Int
        var signedTieBreak: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.exactWeight != rhs.exactWeight { return lhs.exactWeight < rhs.exactWeight }
            if lhs.inRangeWeight != rhs.inRangeWeight { return lhs.inRangeWeight < rhs.inRangeWeight }
            if lhs.movementPenalty != rhs.movementPenalty { return lhs.movementPenalty < rhs.movementPenalty }
            if lhs.absoluteTransposePenalty != rhs.absoluteTransposePenalty { return lhs.absoluteTransposePenalty < rhs.absoluteTransposePenalty }
            return lhs.signedTieBreak < rhs.signedTieBreak
        }
    }

    struct ChromaticTransposeScore: Comparable {
        var movementPenalty: Int
        var collisionPenalty: Int
        var foldPenalty: Int
        var absoluteTransposePenalty: Int
        var signedTieBreak: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.movementPenalty != rhs.movementPenalty { return lhs.movementPenalty < rhs.movementPenalty }
            if lhs.collisionPenalty != rhs.collisionPenalty { return lhs.collisionPenalty < rhs.collisionPenalty }
            if lhs.foldPenalty != rhs.foldPenalty { return lhs.foldPenalty < rhs.foldPenalty }
            if lhs.absoluteTransposePenalty != rhs.absoluteTransposePenalty { return lhs.absoluteTransposePenalty < rhs.absoluteTransposePenalty }
            return lhs.signedTieBreak < rhs.signedTieBreak
        }
    }

    struct AdaptiveCandidate {
        var packets: [PlayableChord]
        var melodyRetained: Int
        var bassRetained: Int
        var salience: Int
        var pitchClassDiversity: Int
        var retainedCount: Int
        var omittedCount: Int
        var unsupportedCount: Int
        var timingOmittedCount: Int
        var collisionCount: Int
        var unplayableCount: Int
        var registerMovement: Int
        var rollDelayMilliseconds: Int
        var sourceTop: Int
        var sourceBottom: Int
        var mappedTop: Int
        var mappedBottom: Int
        var deterministicRank: Int

        var firstLayer: NTELayer { packets[0].layer }
        var lastLayer: NTELayer { packets[packets.count - 1].layer }
    }

    struct AdaptiveScore: Comparable {
        var melodyRetained: Int
        var bassRetained: Int
        var salience: Int
        var pitchClassDiversity: Int
        var retainedCount: Int
        var contourPenalty: Int
        var registerMovementPenalty: Int
        var rollDelayPenalty: Int
        var switchPenalty: Int
        var deterministicTieBreak: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.melodyRetained != rhs.melodyRetained { return lhs.melodyRetained < rhs.melodyRetained }
            if lhs.bassRetained != rhs.bassRetained { return lhs.bassRetained < rhs.bassRetained }
            if lhs.salience != rhs.salience { return lhs.salience < rhs.salience }
            if lhs.pitchClassDiversity != rhs.pitchClassDiversity { return lhs.pitchClassDiversity < rhs.pitchClassDiversity }
            if lhs.retainedCount != rhs.retainedCount { return lhs.retainedCount < rhs.retainedCount }
            if lhs.contourPenalty != rhs.contourPenalty { return lhs.contourPenalty < rhs.contourPenalty }
            if lhs.registerMovementPenalty != rhs.registerMovementPenalty { return lhs.registerMovementPenalty < rhs.registerMovementPenalty }
            if lhs.rollDelayPenalty != rhs.rollDelayPenalty { return lhs.rollDelayPenalty < rhs.rollDelayPenalty }
            if lhs.switchPenalty != rhs.switchPenalty { return lhs.switchPenalty < rhs.switchPenalty }
            return lhs.deterministicTieBreak < rhs.deterministicTieBreak
        }

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(
                melodyRetained: lhs.melodyRetained + rhs.melodyRetained,
                bassRetained: lhs.bassRetained + rhs.bassRetained,
                salience: lhs.salience + rhs.salience,
                pitchClassDiversity: lhs.pitchClassDiversity + rhs.pitchClassDiversity,
                retainedCount: lhs.retainedCount + rhs.retainedCount,
                contourPenalty: lhs.contourPenalty + rhs.contourPenalty,
                registerMovementPenalty: lhs.registerMovementPenalty + rhs.registerMovementPenalty,
                rollDelayPenalty: lhs.rollDelayPenalty + rhs.rollDelayPenalty,
                switchPenalty: lhs.switchPenalty + rhs.switchPenalty,
                deterministicTieBreak: lhs.deterministicTieBreak + rhs.deterministicTieBreak
            )
        }
    }

    func effectiveSimultaneousKeyLimit(settings: PlaybackSettings) -> Int {
        layoutMode == .nte36Chromatic
            ? min(settings.simultaneousKeyLimit, VirtualHIDConstants.maximumKeys)
            : settings.simultaneousKeyLimit
    }

    func manualKeyTranspose(settings: PlaybackSettings) -> Int {
        if layoutMode == .nte21Natural,
           settings.arrangementMode == .original,
           settings.naturalScaleHandling == .transposeSongToFitCMajor {
            return -settings.sourceKey.semitone
        }
        return settings.keyTranspositionSemitones
    }

    func chooseAutomaticTranspose(events: [MidiNoteEvent], manualTranspose: Int, settings: PlaybackSettings) -> Int {
        guard settings.arrangementMode == .automatic else { return 0 }
        if layoutMode == .nte36Chromatic {
            return chooseChromaticAutomaticTranspose(
                events: events,
                manualTranspose: manualTranspose,
                settings: settings
            )
        }

        let candidates = Array(-24...24)
        var bestTranspose = 0
        var bestScore: TransposeScore?
        for transpose in candidates {
            var exactWeight = 0
            for event in events {
                let weight = Int(event.velocity) * 4 + min(200, Int(event.duration * 100)) + 1
                let note = Int(event.midiNote) + manualTranspose + transpose
                let folded = foldIntoRange(note, range: settings.playableRange)
                if NTELayout.naturalSemitones.contains(positiveModulo(folded - settings.baseMidiNoteForBAS1, 12)) {
                    exactWeight += weight
                }
            }
            let score = TransposeScore(
                exactWeight: exactWeight,
                inRangeWeight: 0,
                movementPenalty: 0,
                absoluteTransposePenalty: -abs(transpose),
                signedTieBreak: -transpose
            )
            if bestScore == nil || bestScore! < score {
                bestScore = score
                bestTranspose = transpose
            }
        }
        return bestTranspose
    }

    func chooseChromaticAutomaticTranspose(
        events: [MidiNoteEvent],
        manualTranspose: Int,
        settings: PlaybackSettings
    ) -> Int {
        var bestTranspose = 0
        var bestScore: ChromaticTransposeScore?
        for transpose in [-24, -12, 0, 12, 24] {
            var movement = 0
            var folds = 0
            var collisionSignatures = Set<String>()
            var collisions = 0
            for event in events {
                let weight = Int(event.velocity) * 4 + min(200, Int(event.duration * 100)) + 1
                let reference = Int(event.midiNote) + manualTranspose
                let candidate = reference + transpose
                let folded = foldIntoRange(candidate, range: settings.playableRange)
                movement += abs(folded - reference) * weight
                if folded != candidate { folds += 1 }
                let onsetBucket = Int((event.startTime / settings.chordThreshold).rounded())
                let signature = "\(onsetBucket)-\(folded)"
                if !collisionSignatures.insert(signature).inserted { collisions += 1 }
            }
            let score = ChromaticTransposeScore(
                movementPenalty: -movement,
                collisionPenalty: -collisions,
                foldPenalty: -folds,
                absoluteTransposePenalty: -abs(transpose),
                signedTieBreak: -transpose
            )
            if bestScore == nil || bestScore! < score {
                bestScore = score
                bestTranspose = transpose
            }
        }
        return bestTranspose
    }

    func prepareNotes(
        _ events: [MidiNoteEvent],
        manualTranspose: Int,
        automaticTranspose: Int,
        settings: PlaybackSettings,
        diagnostics: inout MappingDiagnostics,
        isCancelled: () -> Bool
    ) -> [WorkingNote] {
        var result: [WorkingNote] = []
        result.reserveCapacity(events.count)
        let sorted = events.sorted {
            if $0.startTime == $1.startTime { return $0.midiNote < $1.midiNote }
            return $0.startTime < $1.startTime
        }
        for (index, event) in sorted.enumerated() {
            if index.isMultiple(of: 1_024), isCancelled() { break }
            let referenceNote = Int(event.midiNote) + manualTranspose
            var note = referenceNote + automaticTranspose
            let wasOutside = !settings.playableRange.contains(note)
            if wasOutside {
                if note < settings.playableRange.lowerBound { diagnostics.notesBelowRange += 1 }
                else { diagnostics.notesAboveRange += 1 }
            }

            var rangeFolded = false
            if settings.arrangementMode == .automatic {
                let folded = foldIntoRange(note, range: settings.playableRange)
                rangeFolded = folded != note
                note = folded
            } else if wasOutside {
                switch settings.autoFitMode {
                case .off:
                    diagnostics.notesSkipped += 1
                    continue
                case .shiftOctaveIntoRange:
                    let folded = foldIntoRange(note, range: settings.playableRange)
                    rangeFolded = folded != note
                    note = folded
                case .clampOrSkip:
                    note = min(max(note, settings.playableRange.lowerBound), settings.playableRange.upperBound)
                }
            }
            if rangeFolded { diagnostics.notesRangeFolded += 1 }

            var preSnapped = false
            if layoutMode == .nte21Natural {
                let semitone = positiveModulo(note - settings.baseMidiNoteForBAS1, 12)
                if !NTELayout.naturalSemitones.contains(semitone) {
                    if settings.arrangementMode == .original, settings.naturalScaleHandling == .skipUnplayable {
                        diagnostics.notesSkipped += 1
                        continue
                    }
                    guard let snapped = NTELayout.nearestPlayableNote(to: note, in: .natural, range: settings.playableRange) else {
                        diagnostics.notesSkipped += 1
                        continue
                    }
                    note = snapped
                    preSnapped = true
                }
            }
            result.append(
                WorkingNote(
                    source: event,
                    referenceMidiNote: referenceNote,
                    midiNote: note,
                    wasRangeFolded: rangeFolded,
                    wasPreSnapped: preSnapped
                )
            )
        }
        return result
    }

    func mergeDenseRetriggers(
        _ notes: [WorkingNote],
        threshold: TimeInterval,
        diagnostics: inout MappingDiagnostics
    ) -> [WorkingNote] {
        guard threshold > 0 else { return notes }
        var lastSeen: [String: TimeInterval] = [:]
        var kept: [WorkingNote] = []
        kept.reserveCapacity(notes.count)
        for note in notes {
            let signature = "\(note.source.trackIndex)-\(note.source.channel)-\(note.midiNote)"
            if let last = lastSeen[signature], note.source.startTime - last <= threshold {
                diagnostics.densityNotesMerged += 1
                continue
            }
            lastSeen[signature] = note.source.startTime
            kept.append(note)
        }
        return kept
    }

    func group(notes: [WorkingNote], threshold: TimeInterval) -> [WorkingChord] {
        guard let first = notes.first else { return [] }
        var groups: [WorkingChord] = []
        var start = first.source.startTime
        var current: [WorkingNote] = []
        for note in notes {
            if note.source.startTime - start <= threshold { current.append(note) }
            else {
                groups.append(WorkingChord(startTime: start, notes: current))
                start = note.source.startTime
                current = [note]
            }
        }
        if !current.isEmpty { groups.append(WorkingChord(startTime: start, notes: current)) }
        return groups
    }

    func candidateLayers(for chord: WorkingChord, settings: PlaybackSettings) -> [LayerCandidate] {
        let layers: [NTELayer] = layoutMode == .nte21Natural ? [.natural] : NTELayer.allCases
        return layers.map { buildCandidate(for: chord, layer: $0, settings: settings) }
    }

    func buildCandidate(for chord: WorkingChord, layer: NTELayer, settings: PlaybackSettings) -> LayerCandidate {
        let lowest = chord.notes.map(\.midiNote).min()
        let highest = chord.notes.map(\.midiNote).max()
        var candidateStrokes: [CandidateStroke] = []
        var unplayable = 0

        for note in chord.notes {
            let exact = NTELayout.layerSemitones[layer]?.contains(
                positiveModulo(note.midiNote - settings.baseMidiNoteForBAS1, 12)
            ) == true
            let target: Int?
            if exact { target = note.midiNote }
            else if settings.arrangementMode == .automatic || layoutMode == .nte36Chromatic {
                target = NTELayout.nearestPlayableNote(to: note.midiNote, in: layer, range: settings.playableRange)
            } else { target = nil }
            guard let target,
                  let key = NTELayout.key(
                    for: target,
                    baseMidiNote: settings.baseMidiNoteForBAS1,
                    layer: layer,
                    manualOverrides: settings.manualKeyOverrides
                  ) else {
                unplayable += 1
                continue
            }

            var priority = note.weight
            if note.midiNote == lowest { priority += 450 }
            if note.midiNote == highest { priority += 550 }
            priority += exact ? 2_000 : -350
            candidateStrokes.append(
                CandidateStroke(
                    working: note,
                    targetNote: target,
                    key: key,
                    layer: layer,
                    exactInLayer: exact,
                    priority: priority
                )
            )
        }

        candidateStrokes.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.working.source.velocity != $1.working.source.velocity { return $0.working.source.velocity > $1.working.source.velocity }
            if $0.targetNote != $1.targetNote { return $0.targetNote > $1.targetNote }
            return $0.working.source.trackIndex < $1.working.source.trackIndex
        }

        var unique: [CandidateStroke] = []
        var signatures = Set<String>()
        var collisions = 0
        for stroke in candidateStrokes {
            let signature = "\(stroke.key.row.rawValue)-\(stroke.key.keyboardKey.rawValue)"
            if signatures.insert(signature).inserted { unique.append(stroke) }
            else { collisions += 1 }
        }

        let simultaneousKeyLimit = effectiveSimultaneousKeyLimit(settings: settings)
        let omitted = max(0, unique.count - simultaneousKeyLimit)
        unique = Array(unique.prefix(simultaneousKeyLimit))
        unique.sort {
            if $0.key.row != $1.key.row { return rowOrder($0.key.row) < rowOrder($1.key.row) }
            return $0.key.midiNote < $1.key.midiNote
        }

        var snappedCount = 0
        let strokes = unique.map { candidate -> PlayableKeyStroke in
            let snapped = !candidate.exactInLayer || candidate.working.wasPreSnapped
            if snapped { snappedCount += 1 }
            let kind: MappingKind
            if snapped { kind = .snapped }
            else if candidate.working.wasRangeFolded { kind = .rangeFolded }
            else if layer == .natural { kind = .exact }
            else { kind = .modifierExact }
            return PlayableKeyStroke(
                key: candidate.key,
                source: candidate.working.source,
                adjustedMidiNote: candidate.targetNote,
                mappingKind: kind,
                duration: candidate.working.source.duration
            )
        }

        let layerBias: Int
        switch layer {
        case .natural: layerBias = 0
        case .sharp: layerBias = -1
        case .flat: layerBias = -2
        }
        let score = unique.reduce(0) { $0 + $1.priority }
            - ((omitted + unplayable) * 1_500)
            - (collisions * 500)
            + layerBias
        return LayerCandidate(
            startTime: chord.startTime,
            layer: layer,
            strokes: strokes,
            score: score,
            snappedCount: snappedCount,
            collisionCount: collisions,
            omittedCount: omitted,
            unplayableCount: unplayable
        )
    }

    func adaptiveCandidates(
        for chord: WorkingChord,
        nextStartTime: TimeInterval?,
        settings: PlaybackSettings
    ) -> [AdaptiveCandidate] {
        let singlePlans = NTELayer.allCases.map { [$0] }
        let doublePlans = NTELayer.allCases.flatMap { first in
            NTELayer.allCases.compactMap { second in first == second ? nil : [first, second] }
        }
        let plans = singlePlans + doublePlans
        let crossLayer = !NTELayer.allCases.contains { layer in
            let allowed = Set(NTELayout.layerSemitones[layer] ?? [])
            return chord.notes.allSatisfy {
                allowed.contains(positiveModulo($0.midiNote - settings.baseMidiNoteForBAS1, 12))
            }
        }

        var result = plans.enumerated().compactMap { rank, plan in
            buildAdaptiveCandidate(
                for: chord,
                layerPlan: plan,
                nextStartTime: nextStartTime,
                settings: settings,
                deterministicRank: rank
            )
        }
        let hasExactRoll = result.contains { $0.packets.count > 1 }
        if crossLayer, !hasExactRoll {
            for index in result.indices where result[index].packets.count == 1 {
                result[index].timingOmittedCount = result[index].unsupportedCount
            }
        }
        return result
    }

    func buildAdaptiveCandidate(
        for chord: WorkingChord,
        layerPlan: [NTELayer],
        nextStartTime: TimeInterval?,
        settings: PlaybackSettings,
        deterministicRank: Int
    ) -> AdaptiveCandidate? {
        guard let sourceTop = chord.notes.map(\.referenceMidiNote).max(),
              let sourceBottom = chord.notes.map(\.referenceMidiNote).min() else {
            return nil
        }

        var candidateStrokes: [CandidateStroke] = []
        var unsupported = 0
        var unplayable = 0
        for note in chord.notes {
            let semitone = positiveModulo(note.midiNote - settings.baseMidiNoteForBAS1, 12)
            guard let layer = layerPlan.first(where: {
                NTELayout.layerSemitones[$0]?.contains(semitone) == true
            }) else {
                unsupported += 1
                continue
            }
            guard let key = NTELayout.key(
                for: note.midiNote,
                baseMidiNote: settings.baseMidiNoteForBAS1,
                layer: layer,
                manualOverrides: settings.manualKeyOverrides
            ) else {
                unplayable += 1
                continue
            }
            var priority = note.weight
            if note.referenceMidiNote == sourceBottom { priority += 450 }
            if note.referenceMidiNote == sourceTop { priority += 550 }
            candidateStrokes.append(
                CandidateStroke(
                    working: note,
                    targetNote: note.midiNote,
                    key: key,
                    layer: layer,
                    exactInLayer: true,
                    priority: priority
                )
            )
        }

        candidateStrokes.sort(by: candidateStrokePrecedes)
        var unique: [CandidateStroke] = []
        var signatures = Set<String>()
        var collisions = 0
        for stroke in candidateStrokes {
            let signature = "\(stroke.layer.rawValue)-\(stroke.key.row.rawValue)-\(stroke.key.keyboardKey.rawValue)"
            if signatures.insert(signature).inserted { unique.append(stroke) }
            else { collisions += 1 }
        }

        let keyLimit = effectiveSimultaneousKeyLimit(settings: settings)
        let overLimit = max(0, unique.count - keyLimit)
        let selected = Array(unique.prefix(keyLimit))
        guard !selected.isEmpty else { return nil }

        var packets: [PlayableChord] = []
        var playbackOffset: TimeInterval = 0
        for layer in layerPlan {
            let layerStrokes = selected.filter { $0.layer == layer }.sorted {
                if $0.key.row != $1.key.row { return rowOrder($0.key.row) < rowOrder($1.key.row) }
                return $0.targetNote < $1.targetNote
            }
            guard !layerStrokes.isEmpty else { continue }
            if !packets.isEmpty {
                let previousCount = packets[packets.count - 1].strokes.count
                let previousDuration = packetDuration(strokeCount: previousCount, settings: settings)
                let lead = layer.modifier == .none ? 0 : settings.modifierLeadTime
                playbackOffset += previousDuration
                    + settings.modifierReleaseDelay
                    + settings.layerSwitchGap
                    + lead
            }
            let strokes = layerStrokes.map { candidate -> PlayableKeyStroke in
                let kind: MappingKind
                if candidate.working.wasRangeFolded { kind = .rangeFolded }
                else if layer == .natural { kind = .exact }
                else { kind = .modifierExact }
                return PlayableKeyStroke(
                    key: candidate.key,
                    source: candidate.working.source,
                    adjustedMidiNote: candidate.targetNote,
                    mappingKind: kind,
                    duration: candidate.working.source.duration
                )
            }
            packets.append(
                PlayableChord(
                    startTime: chord.startTime,
                    playbackOffset: playbackOffset,
                    layer: layer,
                    strokes: strokes
                )
            )
        }

        guard !packets.isEmpty else { return nil }
        if packets.count > 1, let nextStartTime {
            let available = max(0, (nextStartTime - chord.startTime) / settings.tempoMultiplier)
            let last = packets[packets.count - 1]
            let required = last.playbackOffset + packetDuration(strokeCount: last.strokes.count, settings: settings)
            guard required <= available + 0.000_001 else { return nil }
        }

        let selectedReferences = Set(selected.map { $0.working.source.id })
        let mappedNotes = selected.map(\.targetNote)
        return AdaptiveCandidate(
            packets: packets,
            melodyRetained: chord.notes.contains {
                $0.referenceMidiNote == sourceTop && selectedReferences.contains($0.source.id)
            } ? 1 : 0,
            bassRetained: chord.notes.contains {
                $0.referenceMidiNote == sourceBottom && selectedReferences.contains($0.source.id)
            } ? 1 : 0,
            salience: selected.reduce(0) { $0 + $1.priority },
            pitchClassDiversity: Set(mappedNotes.map {
                positiveModulo($0 - settings.baseMidiNoteForBAS1, 12)
            }).count,
            retainedCount: selected.count,
            omittedCount: unsupported + overLimit,
            unsupportedCount: unsupported,
            timingOmittedCount: 0,
            collisionCount: collisions,
            unplayableCount: unplayable,
            registerMovement: selected.reduce(0) {
                $0 + abs($1.targetNote - $1.working.referenceMidiNote)
            },
            rollDelayMilliseconds: Int(((packets.last?.playbackOffset ?? 0) * 1_000).rounded()),
            sourceTop: sourceTop,
            sourceBottom: sourceBottom,
            mappedTop: mappedNotes.max() ?? sourceTop,
            mappedBottom: mappedNotes.min() ?? sourceBottom,
            deterministicRank: deterministicRank
        )
    }

    func packetDuration(strokeCount: Int, settings: PlaybackSettings) -> TimeInterval {
        guard strokeCount > 0 else { return 0 }
        return Double(strokeCount - 1) * settings.chordStagger + settings.tapDuration
    }

    func candidateStrokePrecedes(_ lhs: CandidateStroke, _ rhs: CandidateStroke) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.working.source.velocity != rhs.working.source.velocity {
            return lhs.working.source.velocity > rhs.working.source.velocity
        }
        if lhs.targetNote != rhs.targetNote { return lhs.targetNote > rhs.targetNote }
        if lhs.working.source.trackIndex != rhs.working.source.trackIndex {
            return lhs.working.source.trackIndex < rhs.working.source.trackIndex
        }
        if lhs.working.source.channel != rhs.working.source.channel {
            return lhs.working.source.channel < rhs.working.source.channel
        }
        return lhs.working.source.startTime < rhs.working.source.startTime
    }

    func selectAdaptiveSequence(_ candidates: [[AdaptiveCandidate]]) -> [AdaptiveCandidate] {
        guard let first = candidates.first, !first.isEmpty else { return [] }
        var scores = first.map(adaptiveLocalScore)
        var backPointers = candidates.map { Array(repeating: 0, count: $0.count) }

        if candidates.count > 1 {
            for chordIndex in 1..<candidates.count {
                guard !candidates[chordIndex].isEmpty else { return [] }
                var nextScores = Array(repeating: adaptiveFloorScore, count: candidates[chordIndex].count)
                for nextIndex in candidates[chordIndex].indices {
                    let current = candidates[chordIndex][nextIndex]
                    for previousIndex in candidates[chordIndex - 1].indices {
                        let previous = candidates[chordIndex - 1][previousIndex]
                        let value = scores[previousIndex]
                            + adaptiveTransitionScore(from: previous, to: current)
                            + adaptiveLocalScore(current)
                        if nextScores[nextIndex] < value {
                            nextScores[nextIndex] = value
                            backPointers[chordIndex][nextIndex] = previousIndex
                        }
                    }
                }
                scores = nextScores
            }
        }

        var selectedIndex = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        var result = Array(repeating: first[0], count: candidates.count)
        for chordIndex in stride(from: candidates.count - 1, through: 0, by: -1) {
            result[chordIndex] = candidates[chordIndex][selectedIndex]
            if chordIndex > 0 { selectedIndex = backPointers[chordIndex][selectedIndex] }
        }
        return result
    }

    var adaptiveFloorScore: AdaptiveScore {
        AdaptiveScore(
            melodyRetained: Int.min / 16,
            bassRetained: Int.min / 16,
            salience: Int.min / 16,
            pitchClassDiversity: Int.min / 16,
            retainedCount: Int.min / 16,
            contourPenalty: Int.min / 16,
            registerMovementPenalty: Int.min / 16,
            rollDelayPenalty: Int.min / 16,
            switchPenalty: Int.min / 16,
            deterministicTieBreak: Int.min / 16
        )
    }

    func adaptiveLocalScore(_ candidate: AdaptiveCandidate) -> AdaptiveScore {
        AdaptiveScore(
            melodyRetained: candidate.melodyRetained,
            bassRetained: candidate.bassRetained,
            salience: candidate.salience,
            pitchClassDiversity: candidate.pitchClassDiversity,
            retainedCount: candidate.retainedCount,
            contourPenalty: 0,
            registerMovementPenalty: -candidate.registerMovement,
            rollDelayPenalty: -candidate.rollDelayMilliseconds,
            switchPenalty: -max(0, candidate.packets.count - 1),
            deterministicTieBreak: -candidate.deterministicRank
        )
    }

    func adaptiveTransitionScore(from previous: AdaptiveCandidate, to current: AdaptiveCandidate) -> AdaptiveScore {
        let topError = abs(
            (current.mappedTop - previous.mappedTop)
                - (current.sourceTop - previous.sourceTop)
        )
        let bottomError = abs(
            (current.mappedBottom - previous.mappedBottom)
                - (current.sourceBottom - previous.sourceBottom)
        )
        return AdaptiveScore(
            melodyRetained: 0,
            bassRetained: 0,
            salience: 0,
            pitchClassDiversity: 0,
            retainedCount: 0,
            contourPenalty: -(topError + bottomError),
            registerMovementPenalty: 0,
            rollDelayPenalty: 0,
            switchPenalty: previous.lastLayer == current.firstLayer ? 0 : -1,
            deterministicTieBreak: 0
        )
    }

    func selectLayerSequence(_ candidates: [[LayerCandidate]]) -> [LayerCandidate] {
        guard !candidates.isEmpty else { return [] }
        if candidates[0].count == 1 { return candidates.compactMap(\.first) }

        let switchPenalty = 425
        var scores = Array(repeating: Int.min / 4, count: candidates[0].count)
        var backPointers = Array(repeating: Array(repeating: 0, count: candidates[0].count), count: candidates.count)
        for index in candidates[0].indices { scores[index] = candidates[0][index].score }

        if candidates.count > 1 {
            for chordIndex in 1..<candidates.count {
                var next = Array(repeating: Int.min / 4, count: candidates[chordIndex].count)
                for nextIndex in candidates[chordIndex].indices {
                    for previousIndex in candidates[chordIndex - 1].indices {
                        let changed = candidates[chordIndex - 1][previousIndex].layer != candidates[chordIndex][nextIndex].layer
                        let value = scores[previousIndex] + candidates[chordIndex][nextIndex].score - (changed ? switchPenalty : 0)
                        if value > next[nextIndex] {
                            next[nextIndex] = value
                            backPointers[chordIndex][nextIndex] = previousIndex
                        }
                    }
                }
                scores = next
            }
        }

        var selectedIndex = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        var result = Array(repeating: candidates[0][0], count: candidates.count)
        for chordIndex in stride(from: candidates.count - 1, through: 0, by: -1) {
            result[chordIndex] = candidates[chordIndex][selectedIndex]
            if chordIndex > 0 { selectedIndex = backPointers[chordIndex][selectedIndex] }
        }
        return result
    }

    func foldIntoRange(_ note: Int, range: ClosedRange<Int>) -> Int {
        var folded = note
        while folded < range.lowerBound { folded += 12 }
        while folded > range.upperBound { folded -= 12 }
        return min(max(folded, range.lowerBound), range.upperBound)
    }

    func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let result = value % modulus
        return result >= 0 ? result : result + modulus
    }

    func rowOrder(_ row: PianoRow) -> Int {
        switch row {
        case .bas: 0
        case .mid: 1
        case .tre: 2
        }
    }

    func warnings(for diagnostics: MappingDiagnostics) -> [String] {
        var result: [String] = []
        if diagnostics.automaticTranspose != 0 {
            result.append("Automatic arrangement transposed the song by \(diagnostics.automaticTranspose) semitones.")
        }
        if diagnostics.notesRangeFolded > 0 { result.append("\(diagnostics.notesRangeFolded) notes were octave-folded into the NTE range.") }
        if diagnostics.notesSnapped > 0 { result.append("\(diagnostics.notesSnapped) notes were moved by one semitone to fit a layer.") }
        if diagnostics.percussionNotesOmitted > 0 { result.append("\(diagnostics.percussionNotesOmitted) General MIDI percussion notes were omitted.") }
        if diagnostics.crossLayerChordsRolled > 0 { result.append("\(diagnostics.crossLayerChordsRolled) cross-layer chords were rolled with exact pitches.") }
        if diagnostics.timingConstrainedTonesOmitted > 0 { result.append("\(diagnostics.timingConstrainedTonesOmitted) exact tones were omitted because there was not enough time to switch layers.") }
        if diagnostics.chordTonesOmitted > 0 { result.append("\(diagnostics.chordTonesOmitted) lower-priority chord tones were omitted during reduction.") }
        if diagnostics.collisionNotesMerged > 0 { result.append("\(diagnostics.collisionNotesMerged) notes mapped to an already-used physical key.") }
        if diagnostics.densityNotesMerged > 0 { result.append("\(diagnostics.densityNotesMerged) retriggers were too close to play cleanly and were merged.") }
        if diagnostics.notesSkipped > 0 { result.append("\(diagnostics.notesSkipped) notes could not be represented.") }
        return result
    }
}
