import XCTest
@testable import NTEPianoMidiPlayerCore

final class NoteMapperTests: XCTestCase {
    func test21KeyRowsUseExactlyTheDocumentedLettersWithoutModifiers() {
        let keys = NTELayout.keys(for: .nte21Natural, baseMidiNote: 48)
        XCTAssertEqual(keys[.tre]?.map(\.keyboardKey), [.q, .w, .e, .r, .t, .y, .u])
        XCTAssertEqual(keys[.mid]?.map(\.keyboardKey), [.a, .s, .d, .f, .g, .h, .j])
        XCTAssertEqual(keys[.bas]?.map(\.keyboardKey), [.z, .x, .c, .v, .b, .n, .m])
        XCTAssertTrue(keys.values.flatMap { $0 }.allSatisfy { $0.modifier == .none })
    }

    func testEvery36KeyLayerUsesSevenFixedKeysOnEveryRow() {
        let expectedSemitones: [NTELayer: [Int]] = [
            .natural: [0, 2, 4, 5, 7, 9, 11],
            .sharp: [1, 2, 4, 6, 8, 9, 11],
            .flat: [0, 2, 3, 5, 7, 9, 10]
        ]
        for row in PianoRow.allCases {
            let rowOffset = NTELayout.rowOffsets[row]!
            let expectedKeys = NTELayout.rowKeys[row]!
            for layer in NTELayer.allCases {
                let actual = expectedSemitones[layer]!.map {
                    NTELayout.key(for: 48 + rowOffset + $0, baseMidiNote: 48, layer: layer)
                }
                let unwrapped = actual.compactMap { $0 }
                XCTAssertEqual(unwrapped.map(\.keyboardKey), expectedKeys)
                XCTAssertTrue(unwrapped.allSatisfy { $0.modifier == layer.modifier })
            }
        }
    }

    func testCompatibleChromaticChordIsAssignedToOneExactSharpLayer() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let result = NTE36ChromaticMapper().map(events: [note(49), note(50), note(52)], settings: settings)

        XCTAssertEqual(result.playableChords.count, 1)
        XCTAssertEqual(result.playableChords[0].layer, .sharp)
        XCTAssertEqual(result.playableChords[0].strokes.map(\.key.keyboardKey), [.z, .x, .c])
        XCTAssertEqual(result.diagnostics.notesSnapped, 0)
    }

    func testSlowCrossLayerChordRollsTwoExactPacketsWithoutSnapping() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 36)
        let result = NTE36ChromaticMapper().map(events: [note(39), note(56)], settings: settings)

        XCTAssertEqual(result.playableChords.count, 2)
        XCTAssertEqual(result.playableChords.map(\.startTime), [0, 0])
        XCTAssertEqual(result.playableChords[0].playbackOffset, 0)
        XCTAssertGreaterThan(result.playableChords[1].playbackOffset, 0)
        XCTAssertEqual(result.playableChords.flatMap(\.strokes).map(\.adjustedMidiNote).sorted(), [39, 56])
        XCTAssertEqual(result.diagnostics.notesSnapped, 0)
        XCTAssertEqual(result.diagnostics.crossLayerChordsRolled, 1)
        XCTAssertEqual(result.diagnostics.timingConstrainedTonesOmitted, 0)
    }

    func testFastCrossLayerChordOmitsInsteadOfChangingPitch() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 36)
        let result = NTE36ChromaticMapper().map(
            events: [note(39), note(56), note(60, start: 0.05)],
            settings: settings
        )

        let firstOnset = result.playableChords.filter { $0.startTime == 0 }
        XCTAssertEqual(firstOnset.count, 1)
        XCTAssertEqual(result.diagnostics.notesSnapped, 0)
        XCTAssertEqual(result.diagnostics.crossLayerChordsRolled, 0)
        XCTAssertEqual(result.diagnostics.timingConstrainedTonesOmitted, 1)
        XCTAssertEqual(result.diagnostics.chordTonesOmitted, 1)
        XCTAssertTrue(firstOnset.flatMap(\.strokes).allSatisfy {
            ($0.adjustedMidiNote - Int($0.source.midiNote)).isMultiple(of: 12)
        })
    }

    func testOriginal36KeyBehaviorStillUsesOneLayerAndSnaps() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 36)
        settings.arrangementMode = .original
        let result = NTE36ChromaticMapper().map(events: [note(39), note(56)], settings: settings)

        XCTAssertEqual(result.playableChords.count, 1)
        XCTAssertEqual(result.diagnostics.notesSnapped, 1)
        XCTAssertEqual(result.diagnostics.crossLayerChordsRolled, 0)
    }

    func testAutomatic36KeyTransposeMinimizesTotalRegisterMovement() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let pitches = Array(36...71)
        let result = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(
            events: pitches.enumerated().map { note($0.element, start: Double($0.offset)) },
            settings: settings
        )

        XCTAssertEqual(result.chosenTranspose, 0)
        XCTAssertEqual(result.mappedEvents.count, pitches.count)
        XCTAssertEqual(result.diagnostics.notesSnapped, 0)
        XCTAssertTrue(result.mappedEvents.allSatisfy {
            ($0.adjustedMidiNote - Int($0.source.midiNote)).isMultiple(of: 12)
        })
    }

    func testAutomatic21KeyFitFindsMinusFourForRunawayPitchClasses() {
        let pitches = [49, 51, 52, 54, 56, 57, 59]
        let settings = PlaybackSettings(layoutMode: .nte21Natural, baseMidiNoteForBAS1: 48)
        let result = UniversalMidiArranger(layoutMode: .nte21Natural).arrange(
            events: pitches.enumerated().map { index, pitch in note(pitch, start: Double(index)) },
            settings: settings
        )

        XCTAssertEqual(result.chosenTranspose, -4)
        XCTAssertEqual(result.mappedEvents.count, pitches.count)
        XCTAssertTrue(result.mappedEvents.allSatisfy { $0.pianoKeys.count == 1 && $0.pianoKey.modifier == .none })
    }

    func testAutomaticModeOmitsPercussionButOriginalKeepsIt() {
        let pitched = note(60, channel: 0)
        let percussion = note(36, channel: 9)
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)

        let automatic = NTE36ChromaticMapper().map(events: [pitched, percussion], settings: settings)
        XCTAssertEqual(automatic.diagnostics.percussionNotesOmitted, 1)
        XCTAssertEqual(automatic.mappedEvents.count, 1)

        settings.arrangementMode = .original
        settings.autoFitMode = .shiftOctaveIntoRange
        let original = NTE36ChromaticMapper().map(events: [pitched, percussion], settings: settings)
        XCTAssertEqual(original.diagnostics.percussionNotesOmitted, 0)
        XCTAssertEqual(original.mappedEvents.count, 2)
    }

    func testChordLimitIsEnforcedAndReportsOmittedTones() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.simultaneousKeyLimit = 3
        let result = NTE36ChromaticMapper().map(
            events: [48, 50, 52, 53, 55, 57].map { note($0) },
            settings: settings
        )
        XCTAssertEqual(result.playableChords[0].strokes.count, 3)
        XCTAssertEqual(result.diagnostics.chordTonesOmitted + result.diagnostics.collisionNotesMerged, 3)
        XCTAssertEqual(result.diagnostics.chordsExceedingLimit, 1)
    }

    func testRolledCrossLayerChordKeepsOneSixVoiceBudgetAcrossPackets() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.simultaneousKeyLimit = 6
        let result = NTE36ChromaticMapper().map(
            events: Array(48...59).map { note($0) },
            settings: settings
        )

        XCTAssertEqual(result.playableChords.flatMap(\.strokes).count, 6)
        XCTAssertTrue(result.playableChords.allSatisfy { $0.strokes.count <= VirtualHIDConstants.maximumKeys })
        XCTAssertTrue(result.playableChords.flatMap(\.strokes).contains { $0.source.midiNote == 48 })
        XCTAssertTrue(result.playableChords.flatMap(\.strokes).contains { $0.source.midiNote == 59 })
        XCTAssertEqual(result.diagnostics.notesSnapped, 0)
        XCTAssertEqual(result.diagnostics.chordTonesOmitted, 6)
    }

    func test36KeyEffectiveLimitIsSixWithoutOverwriting21KeyPreference() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.arrangementMode = .original
        settings.simultaneousKeyLimit = 12
        let pitches = [48, 50, 52, 53, 55, 57, 59, 60]

        let chromatic = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(
            events: pitches.map { note($0) },
            settings: settings
        )
        XCTAssertLessThanOrEqual(chromatic.playableChords[0].strokes.count, 6)
        XCTAssertEqual(settings.simultaneousKeyLimit, 12)

        settings.layoutMode = .nte21Natural
        let natural = UniversalMidiArranger(layoutMode: .nte21Natural).arrange(
            events: pitches.map { note($0) },
            settings: settings
        )
        XCTAssertLessThanOrEqual(natural.playableChords[0].strokes.count, 12)
    }

    func testDenseInputIsBoundedAndDeterministic() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.chordThreshold = 0.01
        var events: [MidiNoteEvent] = []
        events.reserveCapacity(5_000)
        for index in 0..<5_000 {
            let pitch = 36 + (index % 60)
            let start = Double(index / 20) * 0.02
            let velocity = UInt8(30 + (index % 90))
            events.append(note(pitch, start: start, velocity: velocity))
        }
        let arranger = UniversalMidiArranger(layoutMode: .nte36Chromatic)
        let first = arranger.arrange(events: events, settings: settings)
        let second = arranger.arrange(events: events, settings: settings)

        XCTAssertLessThanOrEqual(first.mappedEvents.count, first.playableChords.count * settings.simultaneousKeyLimit)
        XCTAssertEqual(signature(first), signature(second))
    }

    func testCancellationStopsLongArrangementWithoutPublishingPartialChords() {
        let events = (0..<3_000).map { note(36 + ($0 % 60), start: Double($0) * 0.001) }
        var checks = 0
        let result = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(
            events: events,
            settings: PlaybackSettings(),
            isCancelled: {
                checks += 1
                return checks > 1
            }
        )
        XCTAssertTrue(result.playableChords.isEmpty)
    }

    func testRunawayLocalRegressionWhenFixtureIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RUNAWAY_MIDI_PATH"] else {
            throw XCTSkip("Set RUNAWAY_MIDI_PATH to run the local, uncommitted regression file")
        }
        let document = try MidiFileLoader().load(url: URL(fileURLWithPath: path))
        XCTAssertEqual(document.noteEvents.count, 682)

        let chromaticSettings = PlaybackSettings(
            layoutMode: .nte36Chromatic,
            arrangementMode: .automatic,
            baseMidiNoteForBAS1: 48
        )
        let chromatic = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(
            events: document.noteEvents,
            settings: chromaticSettings
        )
        XCTAssertLessThanOrEqual(chromatic.mappedEvents.count, document.noteEvents.count)
        XCTAssertTrue(chromatic.playableChords.allSatisfy { $0.strokes.count <= chromaticSettings.simultaneousKeyLimit })
        XCTAssertEqual(chromatic.diagnostics.notesSnapped, 0)
        XCTAssertEqual(chromatic.diagnostics.densityNotesMerged, 8)
        XCTAssertTrue(chromatic.mappedEvents.allSatisfy {
            ($0.adjustedMidiNote - Int($0.source.midiNote)).isMultiple(of: 12)
        })

        let incompatibleOnsets = document.noteEvents
            .filter { $0.midiNote % 12 == 3 || $0.midiNote % 12 == 8 }
            .reduce(into: [Int: Set<UInt8>]()) { groups, event in
                groups[Int((event.startTime * 1_000).rounded()), default: []].insert(event.midiNote % 12)
            }
            .values
            .filter { $0 == Set([3, 8]) }
        XCTAssertEqual(incompatibleOnsets.count, 8)

        let naturalSettings = PlaybackSettings(
            layoutMode: .nte21Natural,
            arrangementMode: .automatic,
            baseMidiNoteForBAS1: 48
        )
        let natural = UniversalMidiArranger(layoutMode: .nte21Natural).arrange(
            events: document.noteEvents,
            settings: naturalSettings
        )
        XCTAssertEqual(natural.chosenTranspose, -4)
        XCTAssertTrue(natural.mappedEvents.allSatisfy {
            $0.pianoKeys.count == 1 && $0.pianoKey.modifier == .none
        })
    }

    private func signature(_ result: ArrangementResult) -> [String] {
        result.playableChords.map { chord in
            "\(String(format: "%.4f", chord.startTime)):\(chord.layer.rawValue):" + chord.strokes.map {
                "\($0.key.keyboardKey.rawValue)-\($0.adjustedMidiNote)"
            }.joined(separator: ",")
        }
    }

    private func note(
        _ midiNote: Int,
        start: TimeInterval = 0,
        duration: TimeInterval = 0.25,
        channel: UInt8 = 0,
        velocity: UInt8 = 90
    ) -> MidiNoteEvent {
        MidiNoteEvent(
            midiNote: UInt8(clamping: midiNote),
            velocity: velocity,
            startTime: start,
            duration: duration,
            channel: channel,
            trackIndex: Int(channel)
        )
    }
}
