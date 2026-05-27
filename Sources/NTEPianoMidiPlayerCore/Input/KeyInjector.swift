import CoreGraphics
import Foundation

public protocol KeyInjecting: AnyObject {
    var dryRun: Bool { get set }
    var dryRunLog: [String] { get }
    func clearDryRunLog()
    func tapChord(
        _ keys: [PianoKey],
        duration: TimeInterval,
        stagger: TimeInterval,
        modifierMode: ModifierInjectionMode,
        modifierLeadTime: TimeInterval,
        modifierReleaseDelay: TimeInterval,
        dryRunDescription: String?
    )
    func releaseAll()
}

public protocol KeyEventPosting: AnyObject {
    func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool)
    func post(modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool)
}

public final class CGEventKeyInjector: KeyInjecting {
    public var dryRun: Bool
    public private(set) var dryRunLog: [String] = []

    private let eventPoster: KeyEventPosting
    private let logQueue = DispatchQueue(label: "nte-piano-midi-player.key-injector.log")

    public init(dryRun: Bool = true) {
        self.dryRun = dryRun
        self.eventPoster = CGEventKeyPoster()
    }

    init(dryRun: Bool, eventPoster: KeyEventPosting) {
        self.dryRun = dryRun
        self.eventPoster = eventPoster
    }

    public func clearDryRunLog() {
        logQueue.sync {
            dryRunLog.removeAll()
        }
    }

    public func tapChord(
        _ keys: [PianoKey],
        duration: TimeInterval,
        stagger: TimeInterval,
        modifierMode: ModifierInjectionMode = .hardwareStateLeft,
        modifierLeadTime: TimeInterval = 0.035,
        modifierReleaseDelay: TimeInterval = 0.008,
        dryRunDescription: String? = nil
    ) {
        let ordered = EventTimelineBuilder.orderedForInjection(
            keys.map { key in
                MappedNoteEvent(
                    source: MidiNoteEvent(midiNote: UInt8(clamping: key.midiNote), velocity: 1, startTime: 0, duration: duration, channel: 0, trackIndex: 0),
                    adjustedMidiNote: key.midiNote,
                    pianoKeys: [key],
                    mappingKind: key.modifier == .none ? .exact : .modifierExact,
                    startTime: 0,
                    duration: duration
                )
            }
        ).flatMap(\.pianoKeys)

        if dryRun {
            let labels = ordered.map(\.keyboardLabel).joined(separator: ", ")
            let formattedDuration = String(format: "%.3f", duration)
            appendLog("DRY \(dryRunDescription ?? labels) duration=\(formattedDuration)")
            return
        }

        for modifier in [KeyModifier.none, .shift, .control] {
            let subgroup = ordered.filter { $0.modifier == modifier }
            guard !subgroup.isEmpty else { continue }
            pressModifierIfNeeded(modifier, mode: modifierMode, keyDown: true)
            sleepForModifierLeadIfNeeded(modifier, mode: modifierMode, leadTime: modifierLeadTime)
            for key in subgroup {
                post(key: key.keyboardKey, modifier: keyEventModifier(for: modifier, mode: modifierMode), keyDown: true)
                sleep(seconds: stagger)
            }
            sleep(seconds: duration)
            for key in subgroup.reversed() {
                post(key: key.keyboardKey, modifier: keyEventModifier(for: modifier, mode: modifierMode), keyDown: false)
                sleep(seconds: min(stagger, 0.002))
            }
            sleepForModifierReleaseIfNeeded(modifier, mode: modifierMode, releaseDelay: modifierReleaseDelay)
            pressModifierIfNeeded(modifier, mode: modifierMode, keyDown: false)
        }
    }

    public func releaseAll() {
        guard !dryRun else { return }
        for key in KeyboardKey.allCases {
            post(key: key, modifier: .none, keyDown: false)
        }
        eventPoster.post(modifier: .shift, side: .left, keyDown: false)
        eventPoster.post(modifier: .shift, side: .right, keyDown: false)
        eventPoster.post(modifier: .control, side: .left, keyDown: false)
        eventPoster.post(modifier: .control, side: .right, keyDown: false)
    }

    private func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool) {
        eventPoster.post(key: key, modifier: modifier, keyDown: keyDown)
    }

    private func pressModifierIfNeeded(_ modifier: KeyModifier, mode: ModifierInjectionMode, keyDown: Bool) {
        guard modifier != .none else { return }
        switch mode {
        case .hardwareStateLeft, .hybridLeft:
            eventPoster.post(modifier: modifier, side: .left, keyDown: keyDown)
        case .hardwareStateRight:
            eventPoster.post(modifier: modifier, side: .right, keyDown: keyDown)
        case .flagsOnly:
            return
        }
    }

    private func keyEventModifier(for modifier: KeyModifier, mode: ModifierInjectionMode) -> KeyModifier {
        switch mode {
        case .hardwareStateLeft, .hardwareStateRight:
            .none
        case .hybridLeft, .flagsOnly:
            modifier
        }
    }

    private func sleepForModifierLeadIfNeeded(_ modifier: KeyModifier, mode: ModifierInjectionMode, leadTime: TimeInterval) {
        guard modifier != .none, mode != .flagsOnly else { return }
        sleep(seconds: max(leadTime, 0))
    }

    private func sleepForModifierReleaseIfNeeded(_ modifier: KeyModifier, mode: ModifierInjectionMode, releaseDelay: TimeInterval) {
        guard modifier != .none, mode != .flagsOnly else { return }
        sleep(seconds: max(releaseDelay, 0))
    }

    private func appendLog(_ entry: String) {
        logQueue.sync {
            dryRunLog.append(entry)
        }
    }

    private func sleep(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}

public final class CGEventKeyPoster: KeyEventPosting {
    private let eventSource: CGEventSource?

    public init() {
        self.eventSource = CGEventSource(stateID: .hidSystemState)
    }

    public func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: MacVirtualKeyCodes.code(for: key),
            keyDown: keyDown
        ) else { return }
        event.flags = modifier.cgEventFlags
        event.post(tap: .cghidEventTap)
    }

    public func post(modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool) {
        guard let code = MacVirtualKeyCodes.code(for: modifier, side: side),
              let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: keyDown) else {
            return
        }
        event.flags = keyDown ? modifier.cgEventFlags : []
        event.post(tap: .cghidEventTap)
    }
}
