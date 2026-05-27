import XCTest
@testable import NTEPianoMidiPlayerCore

final class KeyInjectorTests: XCTestCase {
    func testHardwareStateLeftUsesModifierKeyEventsWithoutFlags() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(dryRun: false, eventPoster: poster)

        injector.tapChord(
            [key(.z, modifier: .shift, semitone: 1)],
            duration: 0,
            stagger: 0,
            modifierMode: .hardwareStateLeft,
            modifierLeadTime: 0,
            modifierReleaseDelay: 0
        )

        XCTAssertEqual(
            poster.events,
            [
                .modifier(.shift, .left, true),
                .key(.z, .none, true),
                .key(.z, .none, false),
                .modifier(.shift, .left, false)
            ]
        )
    }

    func testHybridLeftUsesModifierKeyEventsAndFlags() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(dryRun: false, eventPoster: poster)

        injector.tapChord(
            [key(.z, modifier: .shift, semitone: 1)],
            duration: 0,
            stagger: 0,
            modifierMode: .hybridLeft,
            modifierLeadTime: 0,
            modifierReleaseDelay: 0
        )

        XCTAssertEqual(
            poster.events,
            [
                .modifier(.shift, .left, true),
                .key(.z, .shift, true),
                .key(.z, .shift, false),
                .modifier(.shift, .left, false)
            ]
        )
    }

    func testFlagsOnlyUsesNoModifierKeyEvents() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(dryRun: false, eventPoster: poster)

        injector.tapChord(
            [key(.m, modifier: .control, semitone: 10)],
            duration: 0,
            stagger: 0,
            modifierMode: .flagsOnly,
            modifierLeadTime: 0,
            modifierReleaseDelay: 0
        )

        XCTAssertEqual(
            poster.events,
            [
                .key(.m, .control, true),
                .key(.m, .control, false)
            ]
        )
    }

    func testHardwareStateRightUsesRightModifierKeyEvents() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(dryRun: false, eventPoster: poster)

        injector.tapChord(
            [key(.m, modifier: .control, semitone: 10)],
            duration: 0,
            stagger: 0,
            modifierMode: .hardwareStateRight,
            modifierLeadTime: 0,
            modifierReleaseDelay: 0
        )

        XCTAssertEqual(
            poster.events,
            [
                .modifier(.control, .right, true),
                .key(.m, .none, true),
                .key(.m, .none, false),
                .modifier(.control, .right, false)
            ]
        )
    }

    func testDryRunLogShowsCompositeLabels() {
        let injector = CGEventKeyInjector(dryRun: true)

        injector.tapChord(
            [
                key(.z, modifier: .none, semitone: 0),
                key(.x, modifier: .none, semitone: 2)
            ],
            duration: 0.032,
            stagger: 0,
            modifierMode: .hardwareStateLeft,
            modifierLeadTime: 0,
            modifierReleaseDelay: 0
        )

        XCTAssertEqual(injector.dryRunLog, ["DRY Z, X duration=0.032"])
    }

    func testDryRunDescriptionOverridesFlattenedKeyList() {
        let injector = CGEventKeyInjector(dryRun: true)

        injector.tapChord(
            [
                key(.z, modifier: .none, semitone: 0),
                key(.x, modifier: .none, semitone: 2)
            ],
            duration: 0.032,
            stagger: 0,
            modifierMode: .hardwareStateLeft,
            modifierLeadTime: 0,
            modifierReleaseDelay: 0,
            dryRunDescription: "C# -> Z+X"
        )

        XCTAssertEqual(injector.dryRunLog, ["DRY C# -> Z+X duration=0.032"])
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
        case modifier(KeyModifier, ModifierKeySide, Bool)
    }

    var events: [Event] = []

    func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool) {
        events.append(.key(key, modifier, keyDown))
    }

    func post(modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool) {
        events.append(.modifier(modifier, side, keyDown))
    }
}
