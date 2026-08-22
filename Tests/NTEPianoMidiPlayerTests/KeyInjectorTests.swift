import CoreGraphics
import XCTest
@testable import NTEPianoMidiPlayerCore

final class KeyInjectorTests: XCTestCase {
    func testHardwareStateLeftUsesModifierKeyEventsWithoutFlags() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(previewMode: false, eventPoster: poster)

        injector.tapChord(
            [key(.z, modifier: .shift, semitone: 1)],
            duration: 0,
            stagger: 0,
            modifierMode: .hardwareStateLeft,
            eventPostTarget: .hidEventTap
        )

        XCTAssertEqual(
            poster.events,
            [
                .modifier(.shift, .left, true, .hidEventTap),
                .key(.z, .none, true, .hidEventTap),
                .key(.z, .none, false, .hidEventTap),
                .modifier(.shift, .left, false, .hidEventTap)
            ]
        )
    }

    func testHybridLeftUsesModifierKeyEventsAndFlags() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(previewMode: false, eventPoster: poster)

        injector.tapChord(
            [key(.z, modifier: .shift, semitone: 1)],
            duration: 0,
            stagger: 0,
            modifierMode: .hybridLeft,
            eventPostTarget: .hidEventTap
        )

        XCTAssertEqual(
            poster.events,
            [
                .modifier(.shift, .left, true, .hidEventTap),
                .key(.z, .shift, true, .hidEventTap),
                .key(.z, .shift, false, .hidEventTap),
                .modifier(.shift, .left, false, .hidEventTap)
            ]
        )
    }

    func testFlagsOnlyUsesNoModifierKeyEvents() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(previewMode: false, eventPoster: poster)

        injector.tapChord(
            [key(.m, modifier: .control, semitone: 10)],
            duration: 0,
            stagger: 0,
            modifierMode: .flagsOnly,
            eventPostTarget: .sessionEventTap
        )

        XCTAssertEqual(
            poster.events,
            [
                .key(.m, .control, true, .sessionEventTap),
                .key(.m, .control, false, .sessionEventTap)
            ]
        )
    }

    func testHardwareStateRightUsesRightModifierKeyEvents() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(previewMode: false, eventPoster: poster)

        injector.tapChord(
            [key(.m, modifier: .control, semitone: 10)],
            duration: 0,
            stagger: 0,
            modifierMode: .hardwareStateRight,
            eventPostTarget: .frontmostPid
        )

        XCTAssertEqual(
            poster.events,
            [
                .modifier(.control, .right, true, .frontmostPid),
                .key(.m, .none, true, .frontmostPid),
                .key(.m, .none, false, .frontmostPid),
                .modifier(.control, .right, false, .frontmostPid)
            ]
        )
    }

    func testHoldModifierCalibrationEmitsOnlyModifierEvents() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(previewMode: false, eventPoster: poster)

        injector.holdModifier(
            .shift,
            mode: .hardwareStateLeft,
            duration: 0,
            eventPostTarget: .sessionEventTap,
            previewDescription: nil
        )

        XCTAssertEqual(
            poster.events,
            [
                .modifier(.shift, .left, true, .sessionEventTap),
                .modifier(.shift, .left, false, .sessionEventTap)
            ]
        )
    }

    func testPreviewLogShowsCompositeLabels() {
        let injector = CGEventKeyInjector(previewMode: true)

        injector.tapChord(
            [
                key(.z, modifier: .none, semitone: 0),
                key(.x, modifier: .none, semitone: 2)
            ],
            duration: 0.032,
            stagger: 0,
            modifierMode: .hardwareStateLeft,
            eventPostTarget: .hidEventTap
        )

        XCTAssertEqual(injector.previewLog, ["PREVIEW Z, X duration=0.032"])
    }

    func testPreviewDescriptionOverridesFlattenedKeyList() {
        let injector = CGEventKeyInjector(previewMode: true)

        injector.tapChord(
            [
                key(.z, modifier: .none, semitone: 0),
                key(.x, modifier: .none, semitone: 2)
            ],
            duration: 0.032,
            stagger: 0,
            modifierMode: .hardwareStateLeft,
            eventPostTarget: .hidEventTap,
            previewDescription: "C# -> Z+X"
        )

        XCTAssertEqual(injector.previewLog, ["PREVIEW C# -> Z+X duration=0.032"])
    }

    func testOverlappingUsesOfSamePhysicalKeyReleaseOnlyAfterLastOwner() {
        let poster = RecordingKeyEventPoster()
        let injector = CGEventKeyInjector(previewMode: false, eventPoster: poster)
        let pianoKey = key(.z, modifier: .none, semitone: 0)

        injector.setKey(pianoKey, keyEventModifier: .none, keyDown: true, eventPostTarget: .hidEventTap)
        injector.setKey(pianoKey, keyEventModifier: .none, keyDown: true, eventPostTarget: .hidEventTap)
        injector.setKey(pianoKey, keyEventModifier: .none, keyDown: false, eventPostTarget: .hidEventTap)
        XCTAssertEqual(poster.events, [.key(.z, .none, true, .hidEventTap)])
        injector.setKey(pianoKey, keyEventModifier: .none, keyDown: false, eventPostTarget: .hidEventTap)
        XCTAssertEqual(
            poster.events,
            [.key(.z, .none, true, .hidEventTap), .key(.z, .none, false, .hidEventTap)]
        )
    }

    func testRecordedKeyboardEventDistinguishesTaggedPlayerInputFromExternalInput() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let playerEvent = try XCTUnwrap(
            CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true)
        )
        playerEvent.flags = .maskShift
        playerEvent.timestamp = 2_500_000
        playerEvent.setIntegerValueField(
            .eventSourceUserData,
            value: KeyboardEventDiagnostics.injectedEventMarker
        )

        let playerRecord = RecordedKeyboardEvent(id: 1, eventType: .flagsChanged, event: playerEvent)

        XCTAssertEqual(playerRecord.origin, .player)
        XCTAssertEqual(playerRecord.keyLabel, "LeftShift")
        XCTAssertEqual(playerRecord.typeLabel, "flagsChanged")
        XCTAssertEqual(playerRecord.flagsLabel, "shift")
        XCTAssertTrue(playerRecord.traceLine(relativeTo: 1_000_000).contains("+    1.500ms"))
        XCTAssertTrue(playerRecord.traceLine(relativeTo: 1_000_000).contains("PLAYER"))

        let externalEvent = try XCTUnwrap(
            CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: true)
        )
        externalEvent.flags = .maskControl
        let externalRecord = RecordedKeyboardEvent(id: 2, eventType: .flagsChanged, event: externalEvent)
        XCTAssertEqual(externalRecord.origin, .external)
        XCTAssertEqual(externalRecord.keyLabel, "LeftCtrl")
        XCTAssertEqual(externalRecord.flagsLabel, "control")
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
        case key(KeyboardKey, KeyModifier, Bool, EventPostTarget)
        case modifier(KeyModifier, ModifierKeySide, Bool, EventPostTarget)
    }

    var events: [Event] = []

    func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool, target: EventPostTarget) {
        events.append(.key(key, modifier, keyDown, target))
    }

    func post(modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool, target: EventPostTarget) {
        events.append(.modifier(modifier, side, keyDown, target))
    }
}
