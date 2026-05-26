import XCTest
@testable import NTEPianoMidiPlayerCore

final class NoteMapperTests: XCTestCase {
    func test36KeyChromaticMappingTableForBASOctave() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let mapper = NTE36ChromaticMapper()
        let expected: [(Int, KeyboardKey, KeyModifier, String)] = [
            (0, .z, .none, "1"),
            (1, .z, .shift, "#1"),
            (2, .x, .none, "2"),
            (3, .c, .control, "b3"),
            (4, .c, .none, "3"),
            (5, .v, .none, "4"),
            (6, .v, .shift, "#4"),
            (7, .b, .none, "5"),
            (8, .b, .shift, "#5"),
            (9, .n, .none, "6"),
            (10, .m, .control, "b7"),
            (11, .m, .none, "7")
        ]

        for (semitone, key, modifier, degree) in expected {
            let result = mapper.map(
                events: [note(48 + semitone)],
                settings: settings
            )
            XCTAssertEqual(result.mappedEvents.count, 1, "semitone \(semitone)")
            XCTAssertEqual(result.mappedEvents[0].pianoKey.keyboardKey, key)
            XCTAssertEqual(result.mappedEvents[0].pianoKey.modifier, modifier)
            XCTAssertEqual(result.mappedEvents[0].pianoKey.degreeLabel, degree)
        }
    }

    func test36KeyRowsUseExpectedKeyboardKeys() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let result = NTE36ChromaticMapper().map(
            events: [note(48), note(60), note(72), note(73), note(82)],
            settings: settings
        )

        XCTAssertEqual(result.mappedEvents.map { $0.pianoKey.keyboardLabel }, ["Z", "A", "Q", "Shift+Q", "Ctrl+U"])
    }

    func test21KeySkipsAccidentalsByDefault() {
        var settings = PlaybackSettings(layoutMode: .nte21Natural, baseMidiNoteForBAS1: 48)
        settings.naturalScaleHandling = .skipUnplayable
        let result = NTE21NaturalMapper().map(
            events: [note(48), note(49), note(50)],
            settings: settings
        )

        XCTAssertEqual(result.mappedEvents.map { $0.pianoKey.keyboardKey }, [.z, .x])
        XCTAssertEqual(result.diagnostics.notesSkipped, 1)
    }

    func test21KeySnapsAccidentalsToNearestNatural() {
        var settings = PlaybackSettings(layoutMode: .nte21Natural, baseMidiNoteForBAS1: 48)
        settings.naturalScaleHandling = .snapToNearest
        let result = NTE21NaturalMapper().map(events: [note(49)], settings: settings)

        XCTAssertEqual(result.mappedEvents.count, 1)
        XCTAssertEqual(result.mappedEvents[0].pianoKey.keyboardKey, .z)
        XCTAssertEqual(result.diagnostics.notesSnapped, 1)
    }

    func testBaseNoteMovesMIDAndTRERanges() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 47)
        XCTAssertEqual(settings.midiNoteForMID1, 59)
        XCTAssertEqual(settings.midiNoteForTRE1, 71)

        let result = NTE36ChromaticMapper().map(events: [note(47), note(59), note(71)], settings: settings)
        XCTAssertEqual(result.mappedEvents.map { $0.pianoKey.keyboardKey }, [.z, .a, .q])
    }

    func testTransposeOctaveRangeAndDuplicateDiagnostics() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.globalTranspose = 12
        settings.octaveShift = -1
        settings.mergeThreshold = 0.015
        let result = NTE36ChromaticMapper().map(
            events: [
                note(60, start: 0.000),
                note(60, start: 0.010),
                note(20, start: 1.000)
            ],
            settings: settings
        )

        XCTAssertEqual(result.mappedEvents.count, 1)
        XCTAssertEqual(result.mappedEvents[0].adjustedMidiNote, 60)
        XCTAssertEqual(result.diagnostics.duplicateNotesMerged, 1)
        XCTAssertEqual(result.diagnostics.notesBelowRange, 1)
    }

    private func note(_ midiNote: Int, start: TimeInterval = 0, duration: TimeInterval = 0.25) -> MidiNoteEvent {
        MidiNoteEvent(
            midiNote: UInt8(midiNote),
            velocity: 90,
            startTime: start,
            duration: duration,
            channel: 0,
            trackIndex: 0
        )
    }
}
