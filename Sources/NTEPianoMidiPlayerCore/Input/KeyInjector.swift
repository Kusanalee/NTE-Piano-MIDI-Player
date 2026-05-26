import CoreGraphics
import Foundation

public protocol KeyInjecting: AnyObject {
    var dryRun: Bool { get set }
    var dryRunLog: [String] { get }
    func clearDryRunLog()
    func tapChord(_ keys: [PianoKey], duration: TimeInterval, stagger: TimeInterval)
    func releaseAll()
}

public protocol KeyEventPosting: AnyObject {
    func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool)
    func post(modifier: KeyModifier, keyDown: Bool)
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

    public func tapChord(_ keys: [PianoKey], duration: TimeInterval, stagger: TimeInterval) {
        let ordered = EventTimelineBuilder.orderedForInjection(
            keys.map { key in
                MappedNoteEvent(
                    source: MidiNoteEvent(midiNote: UInt8(clamping: key.midiNote), velocity: 1, startTime: 0, duration: duration, channel: 0, trackIndex: 0),
                    adjustedMidiNote: key.midiNote,
                    pianoKey: key,
                    startTime: 0,
                    duration: duration
                )
            }
        ).map(\.pianoKey)

        if dryRun {
            let labels = ordered.map(\.keyboardLabel).joined(separator: ", ")
            let formattedDuration = String(format: "%.3f", duration)
            appendLog("DRY \(labels) duration=\(formattedDuration)")
            return
        }

        for modifier in [KeyModifier.none, .shift, .control] {
            let subgroup = ordered.filter { $0.modifier == modifier }
            guard !subgroup.isEmpty else { continue }
            pressModifier(modifier, keyDown: true)
            if modifier != .none {
                sleep(seconds: max(stagger, 0.008))
            }
            for key in subgroup {
                post(key: key.keyboardKey, modifier: modifier, keyDown: true)
                sleep(seconds: stagger)
            }
            sleep(seconds: duration)
            for key in subgroup.reversed() {
                post(key: key.keyboardKey, modifier: modifier, keyDown: false)
                sleep(seconds: min(stagger, 0.002))
            }
            pressModifier(modifier, keyDown: false)
        }
    }

    public func releaseAll() {
        guard !dryRun else { return }
        for key in KeyboardKey.allCases {
            post(key: key, modifier: .none, keyDown: false)
        }
        pressModifier(.shift, keyDown: false)
        pressModifier(.control, keyDown: false)
    }

    private func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool) {
        eventPoster.post(key: key, modifier: modifier, keyDown: keyDown)
    }

    private func pressModifier(_ modifier: KeyModifier, keyDown: Bool) {
        eventPoster.post(modifier: modifier, keyDown: keyDown)
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

    public func post(modifier: KeyModifier, keyDown: Bool) {
        guard let code = MacVirtualKeyCodes.code(for: modifier),
              let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: keyDown) else {
            return
        }
        event.flags = keyDown ? modifier.cgEventFlags : []
        event.post(tap: .cghidEventTap)
    }
}
