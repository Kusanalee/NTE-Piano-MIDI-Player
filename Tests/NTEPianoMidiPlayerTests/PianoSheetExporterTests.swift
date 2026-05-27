import XCTest
@testable import NTEPianoMidiPlayerCore

final class PianoSheetExporterTests: XCTestCase {
    func testExportsKeyboardDegreeAndChordBrackets() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let mapped = NTE36ChromaticMapper().map(
            events: [
                note(48, start: 0),
                note(52, start: 0.005),
                note(55, start: 0.500)
            ],
            settings: settings
        ).mappedEvents

        let text = PianoSheetExporter().export(
            events: mapped,
            options: PianoSheetOptions(
                showNoteNames: false,
                showScaleDegrees: true,
                showKeyboardKeys: true,
                delimiter: " ",
                lineLength: 8,
                useChordBrackets: true
            )
        )

        XCTAssertEqual(text, "[BAS1:Z BAS3:C] BAS5:B")
    }

    func testExportsNoteNamesOnlyWithLineSplits() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let mapped = NTE36ChromaticMapper().map(
            events: [note(48, start: 0), note(50, start: 1), note(52, start: 2)],
            settings: settings
        ).mappedEvents

        let text = PianoSheetExporter().export(
            events: mapped,
            options: PianoSheetOptions(
                showNoteNames: true,
                showScaleDegrees: false,
                showKeyboardKeys: false,
                delimiter: ",",
                lineLength: 2,
                useChordBrackets: true
            )
        )

        XCTAssertEqual(text, "C,D\nE")
    }

    func testCompositeNoteUsesPlusAndMidiChordUsesBrackets() {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let mapped = NTE36ChromaticMapper().map(
            events: [
                note(49, start: 0),
                note(52, start: 0.005)
            ],
            settings: settings
        ).mappedEvents

        let text = PianoSheetExporter().export(
            events: mapped,
            options: PianoSheetOptions(
                showNoteNames: false,
                showScaleDegrees: false,
                showKeyboardKeys: true,
                delimiter: " ",
                lineLength: 8,
                useChordBrackets: true
            )
        )

        XCTAssertEqual(text, "[Z+X C]")
    }

    private func note(_ midiNote: Int, start: TimeInterval) -> MidiNoteEvent {
        MidiNoteEvent(
            midiNote: UInt8(midiNote),
            velocity: 90,
            startTime: start,
            duration: 0.25,
            channel: 0,
            trackIndex: 0
        )
    }
}
