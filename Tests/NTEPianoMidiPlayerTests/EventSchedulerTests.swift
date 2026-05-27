import XCTest
@testable import NTEPianoMidiPlayerCore

final class EventSchedulerTests: XCTestCase {
    func testExactModifierLayerStartsBeforeKeyDown() {
        var settings = exactSettings(countdown: 3.0)
        settings.modifierLeadTime = 0.120
        settings.modifierReleaseDelay = 0.008
        settings.tapDuration = 0.032

        let actions = plannedActions(notes: [49], settings: settings)
        let shiftDown = firstModifierTime(actions, modifier: .shift, keyDown: true)
        let keyDown = firstKeyTime(actions, keyboardKey: .z, noteModifier: .shift, keyDown: true)
        let keyUp = firstKeyTime(actions, keyboardKey: .z, noteModifier: .shift, keyDown: false)
        let shiftUp = firstModifierTime(actions, modifier: .shift, keyDown: false)

        XCTAssertEqual(shiftDown, 2.880, accuracy: 0.000_001)
        XCTAssertEqual(keyDown, 3.000, accuracy: 0.000_001)
        XCTAssertEqual(keyDown - shiftDown, settings.modifierLeadTime, accuracy: 0.000_001)
        XCTAssertLessThan(keyUp, shiftUp)
        XCTAssertEqual(shiftUp - keyUp, settings.modifierReleaseDelay, accuracy: 0.000_001)
    }

    func testFlatLayerStartsBeforeKeyDownAndReleasesAfterKeyUp() {
        var settings = exactSettings(countdown: 1.0)
        settings.modifierLeadTime = 0.120
        settings.modifierReleaseDelay = 0.008
        settings.tapDuration = 0.032

        let actions = plannedActions(notes: [51], settings: settings)
        let controlDown = firstModifierTime(actions, modifier: .control, keyDown: true)
        let keyDown = firstKeyTime(actions, keyboardKey: .c, noteModifier: .control, keyDown: true)
        let keyUp = firstKeyTime(actions, keyboardKey: .c, noteModifier: .control, keyDown: false)
        let controlUp = firstModifierTime(actions, modifier: .control, keyDown: false)

        XCTAssertEqual(controlDown, 0.880, accuracy: 0.000_001)
        XCTAssertEqual(keyDown, 1.000, accuracy: 0.000_001)
        XCTAssertEqual(keyDown - controlDown, settings.modifierLeadTime, accuracy: 0.000_001)
        XCTAssertLessThan(keyUp, controlUp)
        XCTAssertEqual(controlUp - keyUp, settings.modifierReleaseDelay, accuracy: 0.000_001)
    }

    func testConsecutiveSharpNotesReuseHeldShiftInsideReuseWindow() {
        var settings = exactSettings(countdown: 0)
        settings.modifierLeadTime = 0.120
        settings.modifierReleaseDelay = 0.008
        settings.modifierReuseWindow = 0.120
        settings.tapDuration = 0.032

        let actions = plannedActions(
            noteSpecs: [
                (49, 0.200),
                (54, 0.280)
            ],
            settings: settings
        )

        let shiftDowns = modifierTimes(actions, modifier: .shift, keyDown: true)
        let shiftUps = modifierTimes(actions, modifier: .shift, keyDown: false)
        let secondKeyUp = firstKeyTime(actions, keyboardKey: .v, noteModifier: .shift, keyDown: false)

        XCTAssertEqual(shiftDowns.count, 1)
        XCTAssertEqual(shiftUps.count, 1)
        XCTAssertEqual(shiftDowns[0], 0.080, accuracy: 0.000_001)
        XCTAssertGreaterThan(shiftUps[0], secondKeyUp)
    }

    func testNaturalNoteBetweenAccidentalsForcesModifierReleaseBeforeNaturalKeyDown() {
        var settings = exactSettings(countdown: 0)
        settings.modifierLeadTime = 0.120
        settings.modifierReleaseDelay = 0.008
        settings.layerSwitchGap = 0.020
        settings.tapDuration = 0.032

        let actions = plannedActions(
            noteSpecs: [
                (49, 0.200),
                (50, 0.215),
                (54, 0.260)
            ],
            settings: settings
        )

        let firstShiftUp = modifierTimes(actions, modifier: .shift, keyDown: false)[0]
        let naturalDown = firstKeyTime(actions, keyboardKey: .x, noteModifier: .none, keyDown: true)
        let secondShiftDown = modifierTimes(actions, modifier: .shift, keyDown: true)[1]

        XCTAssertEqual(naturalDown - firstShiftUp, settings.layerSwitchGap, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(secondShiftDown - naturalDown, settings.tapDuration + settings.layerSwitchGap)
    }

    func testSharpToFlatTransitionReleasesOldModifierBeforeNewModifierDown() {
        var settings = exactSettings(countdown: 0)
        settings.modifierLeadTime = 0.120
        settings.modifierReleaseDelay = 0.008
        settings.layerSwitchGap = 0.020
        settings.tapDuration = 0.032

        let actions = plannedActions(
            noteSpecs: [
                (49, 0.200),
                (51, 0.220)
            ],
            settings: settings
        )

        let shiftUp = firstModifierTime(actions, modifier: .shift, keyDown: false)
        let controlDown = firstModifierTime(actions, modifier: .control, keyDown: true)
        let flatKeyDown = firstKeyTime(actions, keyboardKey: .c, noteModifier: .control, keyDown: true)

        XCTAssertEqual(controlDown - shiftUp, settings.layerSwitchGap, accuracy: 0.000_001)
        XCTAssertEqual(flatKeyDown - controlDown, settings.modifierLeadTime, accuracy: 0.000_001)
    }

    func testMixedLayerChordSplitsInNaturalSharpFlatOrder() {
        var settings = exactSettings(countdown: 1.0)
        settings.modifierLeadTime = 0.120
        settings.modifierReleaseDelay = 0.008
        settings.tapDuration = 0.032
        settings.chordStagger = 0

        let actions = plannedActions(notes: [48, 49, 51], settings: settings)
        let keyDowns = actions.compactMap { action -> PianoKey? in
            guard case let .key(key, _, keyDown) = action.kind, keyDown else { return nil }
            return key
        }

        XCTAssertEqual(keyDowns.map(\.modifier), [.none, .shift, .control])
        XCTAssertEqual(keyDowns.map(\.keyboardKey), [.z, .z, .c])

        let keyDownTimes = actions.compactMap { action -> TimeInterval? in
            guard case .key(_, _, true) = action.kind else { return nil }
            return action.time
        }
        XCTAssertLessThan(keyDownTimes[0], keyDownTimes[1])
        XCTAssertLessThan(keyDownTimes[1], keyDownTimes[2])
    }

    func testFlagsOnlyDoesNotScheduleModifierKeyActions() {
        var settings = exactSettings(countdown: 0)
        settings.modifierInjectionMode = .flagsOnly
        settings.modifierLeadTime = 0.120

        let actions = plannedActions(noteSpecs: [(49, 0.200)], settings: settings)

        XCTAssertFalse(actions.contains { action in
            if case .modifier = action.kind { return true }
            return false
        })
        let keyDownModifier = actions.compactMap { action -> KeyModifier? in
            guard case let .key(_, keyEventModifier, true) = action.kind else { return nil }
            return keyEventModifier
        }.first
        XCTAssertEqual(keyDownModifier, .shift)
    }

    func testCalibrationLayerSequenceOrdering() {
        var settings = exactSettings(countdown: 1.0)
        settings.modifierLeadTime = 0.120
        settings.modifierReleaseDelay = 0.008
        settings.layerSwitchGap = 0.020
        settings.tapDuration = 0.032

        let actions = plannedActions(
            noteSpecs: [
                (48, 0.00),
                (51, 0.45),
                (50, 0.90),
                (49, 1.35),
                (52, 1.80)
            ],
            settings: settings
        )
        let keyDowns = actions.compactMap { action -> PianoKey? in
            guard case let .key(key, _, true) = action.kind else { return nil }
            return key
        }

        XCTAssertEqual(keyDowns.map(\.modifier), [.none, .control, .none, .shift, .none])
        XCTAssertEqual(keyDowns.map(\.keyboardKey), [.z, .c, .x, .z, .c])
        XCTAssertLessThan(firstModifierTime(actions, modifier: .control, keyDown: false), firstKeyTime(actions, keyboardKey: .x, noteModifier: .none, keyDown: true))
        XCTAssertLessThan(firstModifierTime(actions, modifier: .shift, keyDown: false), firstKeyTime(actions, keyboardKey: .c, noteModifier: .none, keyDown: true))
    }

    private func exactSettings(countdown: Double) -> PlaybackSettings {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.accidentalPlaybackMode = .useShiftCtrlModifiers
        settings.countdownDuration = countdown
        settings.modifierInjectionMode = .hardwareStateLeft
        return settings
    }

    private func plannedActions(notes: [Int], settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        plannedActions(noteSpecs: notes.map { ($0, 0.0) }, settings: settings)
    }

    private func plannedActions(noteSpecs: [(Int, TimeInterval)], settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        let events = noteSpecs.map { midiNote, startTime in
            MidiNoteEvent(
                midiNote: UInt8(midiNote),
                velocity: 90,
                startTime: startTime,
                duration: 0.25,
                channel: 0,
                trackIndex: 0
            )
        }
        let mapped = NTE36ChromaticMapper().map(events: events, settings: settings).mappedEvents
        let groups = EventTimelineBuilder.group(events: mapped, threshold: settings.chordThreshold)
        return LayeredPlaybackPlanner.plan(groups: groups, settings: settings)
    }

    private func firstModifierTime(
        _ actions: [ScheduledPlaybackAction],
        modifier: KeyModifier,
        keyDown: Bool
    ) -> TimeInterval {
        modifierTimes(actions, modifier: modifier, keyDown: keyDown)[0]
    }

    private func modifierTimes(
        _ actions: [ScheduledPlaybackAction],
        modifier: KeyModifier,
        keyDown: Bool
    ) -> [TimeInterval] {
        actions.compactMap { action in
            guard case let .modifier(actionModifier, _, actionKeyDown) = action.kind,
                  actionModifier == modifier,
                  actionKeyDown == keyDown else {
                return nil
            }
            return action.time
        }
    }

    private func firstKeyTime(
        _ actions: [ScheduledPlaybackAction],
        keyboardKey: KeyboardKey,
        noteModifier: KeyModifier,
        keyDown: Bool
    ) -> TimeInterval {
        actions.compactMap { action in
            guard case let .key(key, _, actionKeyDown) = action.kind,
                  key.keyboardKey == keyboardKey,
                  key.modifier == noteModifier,
                  actionKeyDown == keyDown else {
                return nil
            }
            return action.time
        }[0]
    }
}
