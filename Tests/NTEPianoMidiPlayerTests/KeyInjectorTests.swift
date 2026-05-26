import XCTest
@testable import NTEPianoMidiPlayerCore

final class KeyInjectorTests: XCTestCase {
    func testRealInjectionPathPostsShiftAndControlModifierEvents() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(dryRun: false, eventPoster: poster)

        injector.tapChord(
            [
                key(.z, modifier: .shift, semitone: 1),
                key(.m, modifier: .control, semitone: 10),
                key(.x, modifier: .none, semitone: 2)
            ],
            duration: 0,
            stagger: 0
        )

        XCTAssertTrue(poster.events.contains(.modifier(.shift, true)))
        XCTAssertTrue(poster.events.contains(.modifier(.shift, false)))
        XCTAssertTrue(poster.events.contains(.modifier(.control, true)))
        XCTAssertTrue(poster.events.contains(.modifier(.control, false)))
        XCTAssertTrue(poster.events.contains(.key(.z, .shift, true)))
        XCTAssertTrue(poster.events.contains(.key(.z, .shift, false)))
        XCTAssertTrue(poster.events.contains(.key(.m, .control, true)))
        XCTAssertTrue(poster.events.contains(.key(.m, .control, false)))
    }

    func testDryRunLogShowsModifierLabels() {
        let injector = CGEventKeyInjector(dryRun: true)

        injector.tapChord(
            [
                key(.z, modifier: .shift, semitone: 1),
                key(.m, modifier: .control, semitone: 10)
            ],
            duration: 0.032,
            stagger: 0
        )

        XCTAssertEqual(injector.dryRunLog, ["DRY Shift+Z, Ctrl+M duration=0.032"])
    }

    private func key(_ keyboardKey: KeyboardKey, modifier: KeyModifier, semitone: Int) -> PianoKey {
        PianoKey(
            row: .bas,
            semitone: semitone,
            degreeLabel: "\(semitone)",
            noteName: "N\(semitone)",
            keyboardKey: keyboardKey,
            modifier: modifier,
            midiNote: 48 + semitone
        )
    }
}

private final class RecordingKeyEventPoster: KeyEventPosting {
    enum Event: Equatable {
        case key(KeyboardKey, KeyModifier, Bool)
        case modifier(KeyModifier, Bool)
    }

    var events: [Event] = []

    func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool) {
        events.append(.key(key, modifier, keyDown))
    }

    func post(modifier: KeyModifier, keyDown: Bool) {
        events.append(.modifier(modifier, keyDown))
    }
}
