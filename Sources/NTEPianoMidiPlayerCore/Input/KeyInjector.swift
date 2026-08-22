import AppKit
import CoreGraphics
import Foundation

public protocol KeyInjecting: AnyObject {
    var previewMode: Bool { get set }
    var previewLog: [String] { get }
    func clearPreviewLog()
    func tapChord(
        _ keys: [PianoKey],
        duration: TimeInterval,
        stagger: TimeInterval,
        modifierMode: ModifierInjectionMode,
        eventPostTarget: EventPostTarget,
        previewDescription: String?
    )
    func setKey(_ key: PianoKey, keyEventModifier: KeyModifier, keyDown: Bool, eventPostTarget: EventPostTarget)
    func setModifier(_ modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool, eventPostTarget: EventPostTarget)
    func holdModifier(_ modifier: KeyModifier, mode: ModifierInjectionMode, duration: TimeInterval, eventPostTarget: EventPostTarget, previewDescription: String?)
    func recordPreview(_ entry: String)
    func releaseAll()
}

public protocol KeyEventPosting: AnyObject {
    func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool, target: EventPostTarget)
    func post(modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool, target: EventPostTarget)
}

public final class CGEventKeyInjector: KeyInjecting {
    public var previewMode: Bool
    public private(set) var previewLog: [String] = []

    private let eventPoster: KeyEventPosting
    private let logQueue = DispatchQueue(label: "nte-piano-midi-player.key-injector.log")
    private let stateLock = NSLock()
    private var heldKeyCounts: [KeyboardKey: Int] = [:]

    public init(previewMode: Bool = true) {
        self.previewMode = previewMode
        self.eventPoster = CGEventKeyPoster()
    }

    init(previewMode: Bool, eventPoster: KeyEventPosting) {
        self.previewMode = previewMode
        self.eventPoster = eventPoster
    }

    public func clearPreviewLog() {
        logQueue.sync {
            previewLog.removeAll()
        }
    }

    public func tapChord(
        _ keys: [PianoKey],
        duration: TimeInterval,
        stagger: TimeInterval,
        modifierMode: ModifierInjectionMode = .hardwareStateLeft,
        eventPostTarget: EventPostTarget = .hidEventTap,
        previewDescription: String? = nil
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

        if previewMode {
            let labels = ordered.map(\.keyboardLabel).joined(separator: ", ")
            let formattedDuration = String(format: "%.3f", duration)
            appendLog("PREVIEW \(previewDescription ?? labels) duration=\(formattedDuration)")
            return
        }

        for modifier in [KeyModifier.none, .shift, .control] {
            let subgroup = ordered.filter { $0.modifier == modifier }
            guard !subgroup.isEmpty else { continue }
            pressModifierIfNeeded(modifier, mode: modifierMode, keyDown: true, eventPostTarget: eventPostTarget)
            for key in subgroup {
                post(key: key.keyboardKey, modifier: keyEventModifier(for: modifier, mode: modifierMode), keyDown: true, eventPostTarget: eventPostTarget)
                sleep(seconds: stagger)
            }
            sleep(seconds: duration)
            for key in subgroup.reversed() {
                post(key: key.keyboardKey, modifier: keyEventModifier(for: modifier, mode: modifierMode), keyDown: false, eventPostTarget: eventPostTarget)
                sleep(seconds: min(stagger, 0.002))
            }
            pressModifierIfNeeded(modifier, mode: modifierMode, keyDown: false, eventPostTarget: eventPostTarget)
        }
    }

    public func setKey(_ key: PianoKey, keyEventModifier: KeyModifier, keyDown: Bool, eventPostTarget: EventPostTarget) {
        guard !previewMode else { return }
        stateLock.lock()
        let count = heldKeyCounts[key.keyboardKey, default: 0]
        let shouldPost: Bool
        if keyDown {
            heldKeyCounts[key.keyboardKey] = count + 1
            shouldPost = count == 0
        } else if count > 1 {
            heldKeyCounts[key.keyboardKey] = count - 1
            shouldPost = false
        } else {
            heldKeyCounts.removeValue(forKey: key.keyboardKey)
            shouldPost = count == 1
        }
        stateLock.unlock()
        if shouldPost {
            post(key: key.keyboardKey, modifier: keyEventModifier, keyDown: keyDown, eventPostTarget: eventPostTarget)
        }
    }

    public func setModifier(_ modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool, eventPostTarget: EventPostTarget) {
        guard !previewMode else { return }
        eventPoster.post(modifier: modifier, side: side, keyDown: keyDown, target: eventPostTarget)
    }

    public func holdModifier(
        _ modifier: KeyModifier,
        mode: ModifierInjectionMode,
        duration: TimeInterval,
        eventPostTarget: EventPostTarget,
        previewDescription: String?
    ) {
        if previewMode {
            appendLog("PREVIEW \(previewDescription ?? "hold \(modifier.displayName)") duration=\(String(format: "%.3f", duration))")
            return
        }
        pressModifierIfNeeded(modifier, mode: mode, keyDown: true, eventPostTarget: eventPostTarget)
        sleep(seconds: duration)
        pressModifierIfNeeded(modifier, mode: mode, keyDown: false, eventPostTarget: eventPostTarget)
    }

    public func recordPreview(_ entry: String) {
        guard previewMode else { return }
        appendLog("PREVIEW \(entry)")
    }

    public func releaseAll() {
        guard !previewMode else { return }
        stateLock.lock()
        let heldKeys = Array(heldKeyCounts.keys)
        heldKeyCounts.removeAll()
        stateLock.unlock()
        for key in heldKeys {
            post(key: key, modifier: .none, keyDown: false, eventPostTarget: .hidEventTap)
        }
        for target in EventPostTarget.allCases {
            eventPoster.post(modifier: .shift, side: .left, keyDown: false, target: target)
            eventPoster.post(modifier: .shift, side: .right, keyDown: false, target: target)
            eventPoster.post(modifier: .control, side: .left, keyDown: false, target: target)
            eventPoster.post(modifier: .control, side: .right, keyDown: false, target: target)
        }
    }

    private func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool, eventPostTarget: EventPostTarget) {
        eventPoster.post(key: key, modifier: modifier, keyDown: keyDown, target: eventPostTarget)
    }

    private func pressModifierIfNeeded(_ modifier: KeyModifier, mode: ModifierInjectionMode, keyDown: Bool, eventPostTarget: EventPostTarget) {
        guard modifier != .none else { return }
        switch mode {
        case .hardwareStateLeft, .hybridLeft:
            eventPoster.post(modifier: modifier, side: .left, keyDown: keyDown, target: eventPostTarget)
        case .hardwareStateRight:
            eventPoster.post(modifier: modifier, side: .right, keyDown: keyDown, target: eventPostTarget)
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

    private func appendLog(_ entry: String) {
        logQueue.sync {
            previewLog.append(entry)
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

    public func post(key: KeyboardKey, modifier: KeyModifier, keyDown: Bool, target: EventPostTarget) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: MacVirtualKeyCodes.code(for: key),
            keyDown: keyDown
        ) else { return }
        event.flags = modifier.cgEventFlags
        tagAsPlayerGenerated(event)
        post(event, target: target)
    }

    public func post(modifier: KeyModifier, side: ModifierKeySide, keyDown: Bool, target: EventPostTarget) {
        guard let code = MacVirtualKeyCodes.code(for: modifier, side: side),
              let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: keyDown) else {
            return
        }
        event.flags = keyDown ? modifier.cgEventFlags : []
        tagAsPlayerGenerated(event)
        post(event, target: target)
    }

    private func tagAsPlayerGenerated(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: KeyboardEventDiagnostics.injectedEventMarker
        )
    }

    private func post(_ event: CGEvent, target: EventPostTarget) {
        switch target {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .frontmostPid:
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
