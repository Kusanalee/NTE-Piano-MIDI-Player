import XCTest
@testable import NTEPianoMidiPlayerCore

final class EventSchedulerTests: XCTestCase {
    func testCompatibleSharpChordPressesEveryKeyAtSameTime() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.countdownDuration = 1
        settings.chordStagger = 0
        let actions = actions(notes: [49, 50, 52], settings: settings)
        let downs = keyActions(actions, keyDown: true)

        XCTAssertEqual(downs.map(\.time), [1, 1, 1])
        XCTAssertEqual(downs.map(\.key.keyboardKey), [.z, .x, .c])
        XCTAssertEqual(downs.map(\.eventModifier), [.shift, .shift, .shift])
        XCTAssertEqual(modifierActions(actions, .shift, true).first!.time, 0.88, accuracy: 0.000_001)
    }

    func testCompatibleFlatChordUsesOneHeldControlLayer() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.countdownDuration = 0
        let actions = actions(notes: [48, 50, 51], settings: settings)
        let downs = keyActions(actions, keyDown: true)

        XCTAssertEqual(Set(downs.map(\.time)), [0])
        XCTAssertEqual(downs.map(\.key.keyboardKey), [.z, .x, .c])
        XCTAssertEqual(modifierActions(actions, .control, true).count, 1)
        XCTAssertEqual(modifierActions(actions, .control, false).count, 1)
    }

    func testNaturalToneCanRemainInSharpLayerToAvoidModifierThrash() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.countdownDuration = 0
        let result = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(
            events: [note(49, start: 0.2), note(50, start: 0.28)],
            settings: settings
        )
        XCTAssertEqual(result.playableChords.map(\.layer), [.sharp, .sharp])
        let actions = LayeredPlaybackPlanner.plan(chords: result.playableChords, settings: settings)
        XCTAssertEqual(modifierActions(actions, .shift, true).count, 1)
        XCTAssertEqual(modifierActions(actions, .shift, false).count, 1)
    }

    func testRolledCrossLayerChordSchedulesExactPacketsAndOneProgressUpdate() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 36)
        settings.countdownDuration = 0
        let result = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(
            events: [note(39), note(56)],
            settings: settings
        )
        let actions = LayeredPlaybackPlanner.plan(chords: result.playableChords, settings: settings)
        let downs = keyActions(actions, keyDown: true)

        XCTAssertEqual(result.playableChords.count, 2)
        XCTAssertEqual(Set(downs.map { $0.key.modifier }), [.shift, .control])
        XCTAssertEqual(Set(downs.map(\.time)).count, 2)
        XCTAssertEqual(actions.filter { if case .progress = $0.kind { return true }; return false }.count, 1)

        let firstKeyUp = keyActions(actions, keyDown: false).map(\.time).min()!
        let firstModifierUp = actions.compactMap { action -> TimeInterval? in
            guard case let .modifier(_, _, down) = action.kind, !down else { return nil }
            return action.time
        }.min()!
        XCTAssertLessThanOrEqual(firstKeyUp, firstModifierUp)
    }

    func testLayerTransitionReleasesKeysBeforeChangingModifier() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.countdownDuration = 0
        settings.holdSustainedNotes = true
        settings.modifierLeadTime = 0.02
        settings.layerSwitchGap = 0.01
        settings.modifierReleaseDelay = 0.005
        let result = UniversalMidiArranger(layoutMode: .nte36Chromatic).arrange(
            events: [note(49, start: 0.1, duration: 1), note(51, start: 0.4, duration: 1)],
            settings: settings
        )
        let actions = LayeredPlaybackPlanner.plan(chords: result.playableChords, settings: settings)
        let firstKeyUp = keyActions(actions, keyDown: false)[0].time
        let shiftUp = modifierActions(actions, .shift, false)[0].time
        let controlDown = modifierActions(actions, .control, true)[0].time
        XCTAssertLessThanOrEqual(firstKeyUp, shiftUp)
        XCTAssertLessThan(shiftUp, controlDown)
    }

    func testFlagsOnlyPostsNoModifierActionsButFlagsTheKeys() {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.modifierInjectionMode = .flagsOnly
        settings.countdownDuration = 0
        let actions = actions(notes: [49], settings: settings)
        XCTAssertFalse(actions.contains { if case .modifier = $0.kind { return true }; return false })
        XCTAssertEqual(keyActions(actions, keyDown: true).first?.eventModifier, .shift)
    }

    func testPlayableChordDecodesLegacyPayloadWithoutPlaybackOffset() throws {
        let settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        let original = try chord(note: 48, start: 1.25, layer: .natural, settings: settings)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "playbackOffset")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PlayableChord.self, from: legacyData)
        XCTAssertEqual(decoded.startTime, original.startTime)
        XCTAssertEqual(decoded.playbackOffset, 0)
        XCTAssertEqual(decoded.layer, original.layer)
        XCTAssertEqual(decoded.strokes, original.strokes)
    }

    func testPlaybackOffsetIsRealTimeAndDoesNotScaleWithTempo() throws {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.countdownDuration = 0
        settings.tempoMultiplier = 2
        var packet = try chord(note: 48, start: 1, layer: .natural, settings: settings)
        packet.playbackOffset = 0.2

        let actions = LayeredPlaybackPlanner.plan(chords: [packet], settings: settings)
        XCTAssertEqual(keyActions(actions, keyDown: true).first?.time ?? -1, 0.7, accuracy: 0.000_001)
    }

    func testHybridPlaybackInjectsNaturalSharpFlatNaturalSequenceEndToEnd() throws {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.countdownDuration = 0
        settings.modifierInjectionMode = .hybridLeft
        settings.chordStagger = 0
        let chords = try [
            chord(note: 48, start: 0.00, layer: .natural, settings: settings),
            chord(note: 49, start: 0.40, layer: .sharp, settings: settings),
            chord(note: 50, start: 0.55, layer: .sharp, settings: settings),
            chord(note: 51, start: 0.90, layer: .flat, settings: settings),
            chord(note: 52, start: 1.30, layer: .natural, settings: settings)
        ]
        let actions = LayeredPlaybackPlanner.plan(chords: chords, settings: settings)
        let poster = RecordingLayerEventPoster()
        let injector = CGEventKeyInjector(previewMode: false, eventPoster: poster)

        for action in actions {
            switch action.kind {
            case let .key(key, modifier, down):
                injector.setKey(key, keyEventModifier: modifier, keyDown: down, eventPostTarget: settings.eventPostTarget)
            case let .modifier(modifier, side, down):
                injector.setModifier(modifier, side: side, keyDown: down, eventPostTarget: settings.eventPostTarget)
            case .preview, .progress:
                break
            }
        }

        XCTAssertEqual(
            poster.events,
            [
                .key(.z, .none, true),
                .key(.z, .none, false),
                .modifier(.shift, .left, true),
                .key(.z, .shift, true),
                .key(.z, .shift, false),
                .key(.x, .shift, true),
                .key(.x, .shift, false),
                .modifier(.shift, .left, false),
                .modifier(.control, .left, true),
                .key(.c, .control, true),
                .key(.c, .control, false),
                .modifier(.control, .left, false),
                .key(.c, .none, true),
                .key(.c, .none, false)
            ]
        )
        XCTAssertEqual(modifierActions(actions, .shift, true).count, 1)
        XCTAssertEqual(modifierActions(actions, .shift, false).count, 1)
        XCTAssertEqual(modifierActions(actions, .control, true).count, 1)
        XCTAssertEqual(modifierActions(actions, .control, false).count, 1)
    }

    private func actions(notes: [Int], settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        let result = UniversalMidiArranger(layoutMode: settings.layoutMode).arrange(
            events: notes.map { note($0) },
            settings: settings
        )
        return LayeredPlaybackPlanner.plan(chords: result.playableChords, settings: settings)
    }

    private func keyActions(
        _ actions: [ScheduledPlaybackAction],
        keyDown: Bool
    ) -> [(time: TimeInterval, key: PianoKey, eventModifier: KeyModifier)] {
        actions.compactMap { action in
            guard case let .key(key, modifier, down) = action.kind, down == keyDown else { return nil }
            return (action.time, key, modifier)
        }
    }

    private func modifierActions(
        _ actions: [ScheduledPlaybackAction],
        _ modifier: KeyModifier,
        _ keyDown: Bool
    ) -> [ScheduledPlaybackAction] {
        actions.filter {
            guard case let .modifier(value, _, down) = $0.kind else { return false }
            return value == modifier && down == keyDown
        }
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

    private func chord(
        note midiNote: Int,
        start: TimeInterval,
        layer: NTELayer,
        settings: PlaybackSettings
    ) throws -> PlayableChord {
        let key = try XCTUnwrap(
            NTELayout.key(for: midiNote, baseMidiNote: settings.baseMidiNoteForBAS1, layer: layer)
        )
        let source = note(midiNote, start: start, duration: settings.tapDuration)
        return PlayableChord(
            startTime: start,
            layer: layer,
            strokes: [
                PlayableKeyStroke(
                    key: key,
                    source: source,
                    adjustedMidiNote: midiNote,
                    mappingKind: layer == .natural ? .exact : .modifierExact,
                    duration: settings.tapDuration
                )
            ]
        )
    }
}

private final class RecordingLayerEventPoster: KeyEventPosting {
    enum Event: Equatable {
        case key(KeyboardKey, KeyModifier, Bool)
        case modifier(KeyModifier, ModifierKeySide, Bool)
    }

    var events: [Event] = []

    func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool, target: EventPostTarget) {
        events.append(.key(key, modifier, keyDown))
    }

    func post(modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool, target: EventPostTarget) {
        events.append(.modifier(modifier, side, keyDown))
    }
}
