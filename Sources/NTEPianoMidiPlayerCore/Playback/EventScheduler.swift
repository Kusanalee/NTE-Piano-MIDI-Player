import Foundation

public enum PlaybackState: String, Codable, Equatable {
    case idle, countingDown, playing, paused, stopped, completed, lostFocus
}

public enum PlaybackFinishReason: String, Codable, Equatable {
    case completed, stopped, lostFocus
}

public enum ScheduledPlaybackActionKind: Equatable {
    case key(PianoKey, keyEventModifier: KeyModifier, keyDown: Bool)
    case modifier(KeyModifier, ModifierKeySide, keyDown: Bool)
    case preview(String)
    case progress(TimeInterval)
}

public struct ScheduledPlaybackAction: Equatable {
    public var time: TimeInterval
    public var order: Int
    public var kind: ScheduledPlaybackActionKind

    public init(time: TimeInterval, order: Int, kind: ScheduledPlaybackActionKind) {
        self.time = time
        self.order = order
        self.kind = kind
    }
}

public enum LayeredPlaybackPlanner {
    public static func plan(chords: [PlayableChord], settings rawSettings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        let settings = rawSettings.clamped()
        let chords = chords.filter { !$0.strokes.isEmpty }.sorted {
            if $0.startTime == $1.startTime { return $0.playbackOffset < $1.playbackOffset }
            return $0.startTime < $1.startTime
        }
        guard !chords.isEmpty else { return [] }

        var actions: [ScheduledPlaybackAction] = []
        let starts = chords.map {
            settings.countdownDuration + ($0.startTime / settings.tempoMultiplier) + $0.playbackOffset
        }

        for index in chords.indices {
            let chord = chords[index]
            let start = starts[index]
            let modifier = chord.layer.modifier
            let keyModifier = keyEventModifier(for: modifier, mode: settings.modifierInjectionMode)
            let endLimit = nextLayerBoundary(after: index, chords: chords, starts: starts, settings: settings)

            if index == chords.startIndex || chord.startTime != chords[index - 1].startTime {
                actions.append(ScheduledPlaybackAction(time: start, order: 0, kind: .progress(chord.startTime)))
            }
            actions.append(
                ScheduledPlaybackAction(
                    time: start,
                    order: 1,
                    kind: .preview(previewDescription(for: chord))
                )
            )

            for (strokeIndex, stroke) in chord.strokes.enumerated() {
                let down = start + (Double(strokeIndex) * settings.chordStagger)
                let requestedDuration: TimeInterval
                if settings.holdSustainedNotes {
                    requestedDuration = min(
                        max(stroke.duration / settings.tempoMultiplier, settings.tapDuration),
                        settings.maxHoldDuration
                    )
                } else {
                    requestedDuration = settings.tapDuration
                }
                let up = min(down + requestedDuration, endLimit)
                actions.append(
                    ScheduledPlaybackAction(
                        time: down,
                        order: 100 + strokeIndex,
                        kind: .key(stroke.key, keyEventModifier: keyModifier, keyDown: true)
                    )
                )
                actions.append(
                    ScheduledPlaybackAction(
                        time: max(down, up),
                        order: 200 + strokeIndex,
                        kind: .key(stroke.key, keyEventModifier: keyModifier, keyDown: false)
                    )
                )
            }
        }

        appendModifierTransitions(chords: chords, starts: starts, settings: settings, actions: &actions)
        return actions.sorted {
            if $0.time == $1.time { return $0.order < $1.order }
            return $0.time < $1.time
        }
    }

    /// Compatibility adapter used by calibration code and sheet-oriented callers.
    public static func plan(groups: [MappedNoteGroup], settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        let chords = groups.flatMap { group -> [PlayableChord] in
            Dictionary(grouping: group.events.flatMap { event in
                event.pianoKeys.map { ($0.modifier, event, $0) }
            }, by: { $0.0 }).compactMap { modifier, entries in
                let layer: NTELayer
                switch modifier {
                case .none: layer = .natural
                case .shift: layer = .sharp
                case .control: layer = .flat
                }
                let strokes = entries.map { _, event, key in
                    PlayableKeyStroke(
                        key: key,
                        source: event.source,
                        adjustedMidiNote: event.adjustedMidiNote,
                        mappingKind: event.mappingKind,
                        duration: event.duration
                    )
                }
                return PlayableChord(startTime: group.startTime, layer: layer, strokes: strokes)
            }
        }
        return plan(chords: chords, settings: settings)
    }

    private static func nextLayerBoundary(
        after index: Int,
        chords: [PlayableChord],
        starts: [TimeInterval],
        settings: PlaybackSettings
    ) -> TimeInterval {
        guard index + 1 < chords.count else { return .greatestFiniteMagnitude }
        let current = chords[index].layer
        for nextIndex in (index + 1)..<chords.count where chords[nextIndex].layer != current {
            let nextModifier = chords[nextIndex].layer.modifier
            let preparation = nextModifier == .none ? settings.layerSwitchGap : settings.modifierLeadTime + settings.layerSwitchGap
            return max(starts[index], starts[nextIndex] - preparation - settings.modifierReleaseDelay)
        }
        return .greatestFiniteMagnitude
    }

    private static func appendModifierTransitions(
        chords: [PlayableChord],
        starts: [TimeInterval],
        settings: PlaybackSettings,
        actions: inout [ScheduledPlaybackAction]
    ) {
        let side = modifierSide(for: settings.modifierInjectionMode)
        guard settings.modifierInjectionMode != .flagsOnly else { return }
        var active = KeyModifier.none

        for index in chords.indices {
            let desired = chords[index].layer.modifier
            guard desired != active else { continue }
            let start = starts[index]
            let desiredDown = desired == .none ? start : max(0, start - settings.modifierLeadTime)
            if active != .none {
                actions.append(
                    ScheduledPlaybackAction(
                        time: max(0, desiredDown - settings.layerSwitchGap),
                        order: 20,
                        kind: .modifier(active, side, keyDown: false)
                    )
                )
            }
            if desired != .none {
                actions.append(
                    ScheduledPlaybackAction(
                        time: desiredDown,
                        order: 30,
                        kind: .modifier(desired, side, keyDown: true)
                    )
                )
            }
            active = desired
        }

        if active != .none {
            let lastChord = chords[chords.count - 1]
            let lastStart = starts[starts.count - 1]
            let lastDuration = lastChord.strokes.map { stroke -> TimeInterval in
                if settings.holdSustainedNotes {
                    return min(max(stroke.duration / settings.tempoMultiplier, settings.tapDuration), settings.maxHoldDuration)
                }
                return settings.tapDuration
            }.max() ?? settings.tapDuration
            actions.append(
                ScheduledPlaybackAction(
                    time: lastStart + lastDuration + settings.modifierReleaseDelay,
                    order: 300,
                    kind: .modifier(active, side, keyDown: false)
                )
            )
        }
    }

    private static func previewDescription(for chord: PlayableChord) -> String {
        let keys = chord.strokes.map { $0.key.keyboardLabel }.joined(separator: "+")
        return "\(chord.layer.rawValue) chord -> \(keys)"
    }

    private static func keyEventModifier(for modifier: KeyModifier, mode: ModifierInjectionMode) -> KeyModifier {
        switch mode {
        case .hardwareStateLeft, .hardwareStateRight: .none
        case .hybridLeft, .flagsOnly: modifier
        }
    }

    private static func modifierSide(for mode: ModifierInjectionMode) -> ModifierKeySide {
        mode == .hardwareStateRight ? .right : .left
    }
}

public final class EventScheduler {
    private let queue = DispatchQueue(label: "nte-piano-midi-player.scheduler", qos: .userInteractive)
    private let lock = NSLock()
    private var currentRunID = UUID()
    private var stopped = true
    private var paused = false
    private var pauseBegan: UInt64?
    private var pauseDebt: UInt64 = 0
    private weak var activeInjector: KeyInjecting?

    public init() {}

    public func start(
        chords: [PlayableChord],
        settings rawSettings: PlaybackSettings,
        injector: KeyInjecting,
        frontmostGuard: @escaping () -> Bool,
        onStateChange: @escaping (PlaybackState) -> Void,
        onProgress: @escaping (TimeInterval) -> Void,
        onFinish: @escaping (PlaybackFinishReason) -> Void
    ) {
        stop()
        let settings = rawSettings.clamped()
        let actions = LayeredPlaybackPlanner.plan(chords: chords, settings: settings)
        let runID = UUID()

        lock.lock()
        currentRunID = runID
        stopped = false
        paused = false
        pauseBegan = nil
        pauseDebt = 0
        activeInjector = injector
        lock.unlock()

        queue.async { [weak self] in
            self?.run(
                runID: runID,
                hasContent: !chords.isEmpty,
                actions: actions,
                settings: settings,
                injector: injector,
                frontmostGuard: frontmostGuard,
                onStateChange: onStateChange,
                onProgress: onProgress,
                onFinish: onFinish
            )
        }
    }

    public func pause() {
        lock.lock()
        if !stopped, !paused {
            paused = true
            pauseBegan = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        if paused {
            if let pauseBegan { pauseDebt += DispatchTime.now().uptimeNanoseconds - pauseBegan }
            paused = false
            self.pauseBegan = nil
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopped = true
        paused = false
        pauseBegan = nil
        currentRunID = UUID()
        let injector = activeInjector
        activeInjector = nil
        lock.unlock()
        injector?.releaseAll()
    }

    private func run(
        runID: UUID,
        hasContent: Bool,
        actions: [ScheduledPlaybackAction],
        settings: PlaybackSettings,
        injector: KeyInjecting,
        frontmostGuard: @escaping () -> Bool,
        onStateChange: @escaping (PlaybackState) -> Void,
        onProgress: @escaping (TimeInterval) -> Void,
        onFinish: @escaping (PlaybackFinishReason) -> Void
    ) {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        if settings.countdownDuration > 0 { onStateChange(.countingDown) }
        guard hasContent else {
            onStateChange(.completed)
            onFinish(.completed)
            return
        }

        var enteredPlaying = settings.countdownDuration <= 0
        if enteredPlaying { onStateChange(.playing) }
        for action in actions {
            if !enteredPlaying, action.time >= settings.countdownDuration {
                guard wait(until: settings.countdownDuration, startNanos: startNanos, runID: runID) else {
                    finishStopped(injector: injector, onStateChange: onStateChange, onFinish: onFinish)
                    return
                }
                enteredPlaying = true
                onStateChange(.playing)
            }
            guard wait(until: action.time, startNanos: startNanos, runID: runID) else {
                finishStopped(injector: injector, onStateChange: onStateChange, onFinish: onFinish)
                return
            }
            if action.needsFrontmostApp, !frontmostGuard() {
                injector.releaseAll()
                onStateChange(.lostFocus)
                onFinish(.lostFocus)
                return
            }
            switch action.kind {
            case let .key(key, modifier, down):
                injector.setKey(key, keyEventModifier: modifier, keyDown: down, eventPostTarget: settings.eventPostTarget)
            case let .modifier(modifier, side, down):
                injector.setModifier(modifier, side: side, keyDown: down, eventPostTarget: settings.eventPostTarget)
            case let .preview(entry):
                injector.recordPreview(entry)
            case let .progress(time):
                onProgress(time)
            }
        }
        injector.releaseAll()
        onStateChange(.completed)
        onFinish(.completed)
    }

    private func finishStopped(
        injector: KeyInjecting,
        onStateChange: (PlaybackState) -> Void,
        onFinish: (PlaybackFinishReason) -> Void
    ) {
        injector.releaseAll()
        onStateChange(.stopped)
        onFinish(.stopped)
    }

    private func wait(until seconds: TimeInterval, startNanos: UInt64, runID: UUID) -> Bool {
        let targetOffset = UInt64(max(0, seconds) * 1_000_000_000)
        while true {
            lock.lock()
            let valid = !stopped && currentRunID == runID
            let isPaused = paused
            let debt = pauseDebt
            lock.unlock()
            guard valid else { return false }
            if isPaused {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            let target = startNanos + targetOffset + debt
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= target { return true }
            Thread.sleep(forTimeInterval: min(max(TimeInterval(target - now) / 1_000_000_000, 0.001), 0.005))
        }
    }
}

private extension ScheduledPlaybackAction {
    var needsFrontmostApp: Bool {
        switch kind {
        case .key, .modifier: true
        case .preview, .progress: false
        }
    }
}
