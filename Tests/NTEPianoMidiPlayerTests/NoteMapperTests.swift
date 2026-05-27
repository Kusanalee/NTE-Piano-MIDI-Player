import XCTest
@testable import NTEPianoMidiPlayerCore

final class NoteMapperTests: XCTestCase {
    func test36KeyAccidentalsApproximateWithNeighborsByDefault() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let result = NTE36ChromaticMapper().map(events: [note(49), note(51), note(54), note(56), note(58)], settings: settings)

        XCTAssertEqual(result.mappedEvents.map(\.keyboardLabel), ["Z+X", "X+C", "V+B", "B+N", "N+M"])
        XCTAssertEqual(result.diagnostics.notesApproximated, 5)
        XCTAssertEqual(result.diagnostics.multiKeyExpandedNotes, 5)
    }

    func test36KeyChromaticMappingTableWhenModifierModeSelected() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.accidentalPlaybackMode = .useShiftCtrlModifiers
        let mapper = NTE36ChromaticMapper()
        let expected: [(Int, KeyboardKey, KeyModifier, String, MappingKind)] = [
            (0, .z, .none, "1", .exact),
            (1, .z, .shift, "#1", .modifierExact),
            (2, .x, .none, "2", .exact),
            (3, .c, .control, "b3", .modifierExact),
            (4, .c, .none, "3", .exact),
            (5, .v, .none, "4", .exact),
            (6, .v, .shift, "#4", .modifierExact),
            (7, .b, .none, "5", .exact),
            (8, .b, .shift, "#5", .modifierExact),
            (9, .n, .none, "6", .exact),
            (10, .m, .control, "b7", .modifierExact),
            (11, .m, .none, "7", .exact)
        ]

        for (semitone, key, modifier, degree, kind) in expected {
            let result = mapper.map(events: [note(48 + semitone)], settings: settings)
            XCTAssertEqual(result.mappedEvents.count, 1, "semitone \(semitone)")
            XCTAssertEqual(result.mappedEvents[0].pianoKeys.count, 1)
            XCTAssertEqual(result.mappedEvents[0].pianoKey.keyboardKey, key)
            XCTAssertEqual(result.mappedEvents[0].pianoKey.modifier, modifier)
            XCTAssertEqual(result.mappedEvents[0].pianoKey.degreeLabel, degree)
            XCTAssertEqual(result.mappedEvents[0].mappingKind, kind)
        }
    }

    func test21KeyAccidentalsApproximateWithNeighbors() {
        var settings = PlaybackSettings(layoutMode: .nte21Natural, baseMidiNoteForBAS1: 48)
        settings.naturalScaleHandling = .skipUnplayable
        let result = NTE21NaturalMapper().map(events: [note(49), note(51), note(54), note(56), note(58)], settings: settings)

        XCTAssertEqual(result.mappedEvents.map(\.keyboardLabel), ["Z+X", "X+C", "V+B", "B+N", "N+M"])
        XCTAssertEqual(result.diagnostics.notesSkipped, 0)
        XCTAssertEqual(result.diagnostics.notesApproximated, 5)
    }

    func test21KeyCanStillSnapWhenApproximationDisabled() {
        var settings = PlaybackSettings(layoutMode: .nte21Natural, baseMidiNoteForBAS1: 48)
        settings.multiKeyApproximationEnabled = false
        settings.naturalScaleHandling = .snapToNearest
        let result = NTE21NaturalMapper().map(events: [note(49)], settings: settings)

        XCTAssertEqual(result.mappedEvents.count, 1)
        XCTAssertEqual(result.mappedEvents[0].pianoKey.keyboardKey, .z)
        XCTAssertEqual(result.mappedEvents[0].mappingKind, .snapped)
        XCTAssertEqual(result.diagnostics.notesSnapped, 1)
    }

    func testBaseNoteMovesMIDAndTRERanges() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 47)
        XCTAssertEqual(settings.midiNoteForMID1, 59)
        XCTAssertEqual(settings.midiNoteForTRE1, 71)

        let result = NTE36ChromaticMapper().map(events: [note(47), note(59), note(71)], settings: settings)
        XCTAssertEqual(result.mappedEvents.map(\.keyboardLabel), ["Z", "A", "Q"])
    }

    func testOutOfRangeNotesFoldIntoRangeAndCanAddThirdColorKey() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.maxApproximationKeys = 3
        let result = NTE36ChromaticMapper().map(events: [note(37)], settings: settings)

        XCTAssertEqual(result.mappedEvents.count, 1)
        XCTAssertEqual(result.mappedEvents[0].adjustedMidiNote, 49)
        XCTAssertEqual(result.mappedEvents[0].mappingKind, .rangeFolded)
        XCTAssertEqual(result.mappedEvents[0].keyboardLabel, "Z+X+A")
        XCTAssertEqual(result.diagnostics.notesBelowRange, 1)
        XCTAssertEqual(result.diagnostics.notesRangeFolded, 1)
    }

    func testDuplicateMergeUsesCompositeSignature() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.mergeThreshold = 0.015
        let result = NTE36ChromaticMapper().map(
            events: [
                note(49, start: 0.000),
                note(49, start: 0.010),
                note(50, start: 0.030)
            ],
            settings: settings
        )

        XCTAssertEqual(result.mappedEvents.map(\.keyboardLabel), ["Z+X", "X"])
        XCTAssertEqual(result.diagnostics.duplicateNotesMerged, 1)
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
