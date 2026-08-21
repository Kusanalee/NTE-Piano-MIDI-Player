import XCTest
@testable import NTEPianoMidiPlayerCore

final class VirtualHIDProtocolTests: XCTestCase {
    func testFixedFrameRoundTripsCompleteKeyboardReport() throws {
        let frame = try VirtualHIDFrame(
            command: .setReport,
            sequence: 42,
            status: .ready,
            modifiers: [.leftShift],
            keys: [KeyboardKey.q.hidUsage, KeyboardKey.a.hidUsage, KeyboardKey.z.hidUsage]
        )

        let encoded = frame.encoded()
        XCTAssertEqual(encoded.count, 64)
        XCTAssertEqual(try VirtualHIDFrame(decoding: encoded), frame)
    }

    func testFrameRejectsReservedBytesUnsupportedModifiersAndDuplicateKeys() throws {
        var reserved = try VirtualHIDFrame(command: .heartbeat, sequence: 1).encoded()
        reserved[36] = 1
        XCTAssertThrowsError(try VirtualHIDFrame(decoding: reserved)) { error in
            XCTAssertEqual(error as? VirtualHIDProtocolError, .invalidReservedBytes)
        }

        XCTAssertThrowsError(
            try VirtualHIDFrame(command: .setReport, modifiers: VirtualHIDModifiers(rawValue: 0x80))
        ) { error in
            XCTAssertEqual(error as? VirtualHIDProtocolError, .unsupportedModifiers)
        }

        XCTAssertThrowsError(
            try VirtualHIDFrame(command: .setReport, keys: [KeyboardKey.a.hidUsage, KeyboardKey.a.hidUsage])
        ) { error in
            XCTAssertEqual(error as? VirtualHIDProtocolError, .invalidKeys)
        }

        XCTAssertThrowsError(
            try VirtualHIDFrame(command: .heartbeat, modifiers: [.leftShift])
        ) { error in
            XCTAssertEqual(error as? VirtualHIDProtocolError, .invalidCommandPayload)
        }

        var malformedHeartbeat = try VirtualHIDFrame(
            command: .setReport,
            sequence: 2,
            modifiers: [.leftShift]
        ).encoded()
        malformedHeartbeat[6] = UInt8(VirtualHIDCommand.heartbeat.rawValue)
        malformedHeartbeat[7] = 0
        XCTAssertThrowsError(try VirtualHIDFrame(decoding: malformedHeartbeat)) { error in
            XCTAssertEqual(error as? VirtualHIDProtocolError, .invalidCommandPayload)
        }
    }

    func testReportRejectsMoreThanSixKeys() {
        XCTAssertThrowsError(
            try VirtualHIDKeyboardReport(keys: Array(0x04...0x0A))
        ) { error in
            XCTAssertEqual(error as? VirtualHIDProtocolError, .tooManyKeys)
        }
    }
}

final class VirtualHIDKeyInjectorTests: XCTestCase {
    func testNaturalSharpFlatNaturalUsesCompleteHardwareReportsAndReusesModifiers() throws {
        var settings = PlaybackSettings(layoutMode: .nte36Chromatic, baseMidiNoteForBAS1: 48)
        settings.countdownDuration = 0
        settings.modifierInjectionMode = .hardwareStateLeft
        settings.tapDuration = 0.032
        let chords = try [
            chord(note: 48, start: 0.00, layer: .natural, settings: settings),
            chord(note: 49, start: 0.40, layer: .sharp, settings: settings),
            chord(note: 50, start: 0.55, layer: .sharp, settings: settings),
            chord(note: 51, start: 0.90, layer: .flat, settings: settings),
            chord(note: 52, start: 1.30, layer: .natural, settings: settings)
        ]
        let actions = LayeredPlaybackPlanner.plan(chords: chords, settings: settings)
        let transport = RecordingVirtualHIDTransport()
        let injector = VirtualHIDKeyInjector(previewMode: false, transport: transport)

        for action in actions {
            switch action.kind {
            case let .key(key, modifier, down):
                injector.setKey(key, keyEventModifier: modifier, keyDown: down, eventPostTarget: .hidEventTap)
            case let .modifier(modifier, side, down):
                injector.setModifier(modifier, side: side, keyDown: down, eventPostTarget: .hidEventTap)
            case .preview, .progress:
                break
            }
        }
        injector.releaseAll()

        XCTAssertEqual(
            transport.events,
            [
                .report(try report(keys: [.z])),
                .report(try report()),
                .report(try report(modifiers: [.leftShift])),
                .report(try report(modifiers: [.leftShift], keys: [.z])),
                .report(try report(modifiers: [.leftShift])),
                .report(try report(modifiers: [.leftShift], keys: [.x])),
                .report(try report(modifiers: [.leftShift])),
                .report(try report()),
                .report(try report(modifiers: [.leftControl])),
                .report(try report(modifiers: [.leftControl], keys: [.c])),
                .report(try report(modifiers: [.leftControl])),
                .report(try report()),
                .report(try report(keys: [.c])),
                .report(try report()),
                .releaseAll
            ]
        )
    }

    func testOverlappingOwnersReleasePhysicalKeyOnlyAfterLastOwner() throws {
        let transport = RecordingVirtualHIDTransport()
        let injector = VirtualHIDKeyInjector(previewMode: false, transport: transport)
        let key = try XCTUnwrap(NTELayout.key(for: 48, baseMidiNote: 48, layer: .natural))

        injector.setKey(key, keyEventModifier: .none, keyDown: true, eventPostTarget: .hidEventTap)
        injector.setKey(key, keyEventModifier: .none, keyDown: true, eventPostTarget: .hidEventTap)
        injector.setKey(key, keyEventModifier: .none, keyDown: false, eventPostTarget: .hidEventTap)
        XCTAssertEqual(transport.events, [.report(try report(keys: [.z]))])
        injector.setKey(key, keyEventModifier: .none, keyDown: false, eventPostTarget: .hidEventTap)
        XCTAssertEqual(transport.events, [.report(try report(keys: [.z])), .report(try report())])
    }

    func testAllPianoLettersMapToWhitelistedHIDUsages() {
        let usages = Set(KeyboardKey.allCases.map(\.hidUsage))
        XCTAssertEqual(usages.count, 21)
        XCTAssertTrue(usages.allSatisfy { (0x04...0x1D).contains($0) })
    }

    private func report(
        modifiers: VirtualHIDModifiers = [],
        keys: [KeyboardKey] = []
    ) throws -> VirtualHIDKeyboardReport {
        try VirtualHIDKeyboardReport(modifiers: modifiers, keys: keys.map(\.hidUsage))
    }

    private func chord(
        note midiNote: Int,
        start: TimeInterval,
        layer: NTELayer,
        settings: PlaybackSettings
    ) throws -> PlayableChord {
        let key = try XCTUnwrap(NTELayout.key(for: midiNote, baseMidiNote: settings.baseMidiNoteForBAS1, layer: layer))
        let source = MidiNoteEvent(
            midiNote: UInt8(midiNote),
            velocity: 90,
            startTime: start,
            duration: settings.tapDuration,
            channel: 0,
            trackIndex: 0
        )
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

private final class RecordingVirtualHIDTransport: VirtualHIDReportTransport {
    enum Event: Equatable {
        case report(VirtualHIDKeyboardReport)
        case heartbeat
        case releaseAll
    }

    var status: VirtualHIDConnectionStatus = .ready
    private(set) var events: [Event] = []

    func refreshStatus() -> VirtualHIDConnectionStatus { status }
    func send(report: VirtualHIDKeyboardReport) throws { events.append(.report(report)) }
    func sendHeartbeat() throws { events.append(.heartbeat) }
    func releaseAll() throws { events.append(.releaseAll) }
    func disconnect() {}
}
