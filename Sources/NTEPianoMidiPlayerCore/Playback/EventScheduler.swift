import Foundation

public enum PlaybackState: String, Codable, Equatable {
    case idle
    case countingDown
    case playing
    case paused
    case stopped
    case completed
    case lostFocus
}

public enum PlaybackFinishReason: String, Codable, Equatable {
    case completed
    case stopped
    case lostFocus
}

public enum ScheduledPlaybackActionKind: Equatable {
    case key(PianoKey, keyEventModifier: KeyModifier, keyDown: Bool)
    case modifier(KeyModifier, ModifierKeySide, keyDown: Bool)
    case dryRun(String)
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
    private struct LayerTap {
        var startTime: TimeInterval
        var duration: TimeInterval
        var modifier: KeyModifier
        var keys: [PianoKey]
    }

    private struct ModifierSpan {
        var downTime: TimeInterval
        var upTime: TimeInterval
        var firstKeyDownTime: TimeInterval
        var modifier: KeyModifier
    }

    public static func plan(groups: [MappedNoteGroup], settings rawSettings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        let settings = rawSettings.clamped()
        var actions: [ScheduledPlaybackAction] = []
        var taps: [LayerTap] = []

        for group in groups {
            let baseTime = settings.countdownDuration + (group.startTime / settings.tempoMultiplier)
            let duration = keyPressDuration(for: group, settings: settings)
            actions.append(
                ScheduledPlaybackAction(
                    time: baseTime,
                    order: 0,
                    kind: .dryRun("\(dryRunDescription(for: group, settings: settings)) duration=\(String(format: "%.3f", duration))")
                )
            )
            actions.append(
                ScheduledPlaybackAction(
                    time: baseTime,
                    order: 900,
                    kind: .progress(group.startTime)
                )
            )

            let groupedKeys = keysByModifier(for: group)
            let activeLayers = [KeyModifier.none, .shift, .control].filter { !(groupedKeys[$0] ?? []).isEmpty }
            let layerStride = layerStride(for: groupedKeys, duration: duration, settings: settings)
            for (layerIndex, modifier) in activeLayers.enumerated() {
                guard let keys = groupedKeys[modifier], !keys.isEmpty else { continue }
                let layerOffset = activeLayers.count > 1 ? layerStride * Double(layerIndex) : 0
                let tap = LayerTap(
                    startTime: baseTime + layerOffset,
                    duration: duration,
                    modifier: modifier,
                    keys: keys
                )
                taps.append(tap)
                actions.append(contentsOf: keyActions(for: tap, settings: settings))
            }
        }

        actions.append(contentsOf: modifierActions(for: taps, settings: settings))
        return actions.sorted {
            if $0.time == $1.time {
                return $0.order < $1.order
            }
            return $0.time < $1.time
        }
    }

    private static func keysByModifier(for group: MappedNoteGroup) -> [KeyModifier: [PianoKey]] {
        var result: [KeyModifier: [PianoKey]] = [:]
        for event in group.events {
            for key in event.pianoKeys {
                if !(result[key.modifier] ?? []).contains(where: { existing in
                    existing.keyboardKey == key.keyboardKey && existing.modifier == key.modifier
                }) {
                    result[key.modifier, default: []].append(key)
                }
            }
        }
        return result
    }

    private static func keyActions(for tap: LayerTap, settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        var actions: [ScheduledPlaybackAction] = []
        let keyEventModifier = keyEventModifier(for: tap.modifier, mode: settings.modifierInjectionMode)

        for (index, key) in tap.keys.enumerated() {
            let downTime = tap.startTime + (Double(index) * settings.chordStagger)
            let upTime = downTime + tap.duration
            actions.append(
                ScheduledPlaybackAction(
                    time: downTime,
                    order: 100 + index,
                    kind: .key(key, keyEventModifier: keyEventModifier, keyDown: true)
                )
            )
            actions.append(
                ScheduledPlaybackAction(
                    time: upTime,
                    order: 200 + index,
                    kind: .key(key, keyEventModifier: keyEventModifier, keyDown: false)
                )
            )
        }
        return actions
    }

    private static func modifierActions(for taps: [LayerTap], settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        guard settings.modifierInjectionMode != .flagsOnly else { return [] }
        let side = modifierSide(for: settings.modifierInjectionMode)
        let modifierTaps = taps
            .filter { $0.modifier != .none }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return modifierOrder(lhs.modifier) < modifierOrder(rhs.modifier)
                }
                return lhs.startTime < rhs.startTime
            }

        var spans: [ModifierSpan] = []
        for tap in modifierTaps {
            let firstKeyDownTime = tap.startTime
            let lastKeyUpTime = tap.keys.enumerated().map { index, _ in
                tap.startTime + (Double(index) * settings.chordStagger) + tap.duration
            }.max() ?? (tap.startTime + tap.duration)
            let candidate = ModifierSpan(
                downTime: max(0, tap.startTime - settings.modifierLeadTime),
                upTime: lastKeyUpTime + settings.modifierReleaseDelay,
                firstKeyDownTime: firstKeyDownTime,
                modifier: tap.modifier
            )

            if let last = spans.last,
               last.modifier == candidate.modifier,
               candidate.downTime <= last.upTime + settings.modifierReuseWindow,
               !hasOtherLayerTapBetween(taps, modifier: candidate.modifier, from: last.upTime, to: candidate.firstKeyDownTime) {
                spans[spans.count - 1].upTime = max(last.upTime, candidate.upTime)
            } else {
                spans.append(candidate)
            }
        }

        return spans.flatMap { span in
            [
                ScheduledPlaybackAction(
                    time: span.downTime,
                    order: 10,
                    kind: .modifier(span.modifier, side, keyDown: true)
                ),
                ScheduledPlaybackAction(
                    time: span.upTime,
                    order: 300,
                    kind: .modifier(span.modifier, side, keyDown: false)
                )
            ]
        }
    }

    private static func hasOtherLayerTapBetween(
        _ taps: [LayerTap],
        modifier: KeyModifier,
        from lowerBound: TimeInterval,
        to upperBound: TimeInterval
    ) -> Bool {
        taps.contains { tap in
            tap.modifier != modifier &&
                tap.startTime >= lowerBound &&
                tap.startTime < upperBound
        }
    }

    private static func layerStride(
        for groupedKeys: [KeyModifier: [PianoKey]],
        duration: TimeInterval,
        settings: PlaybackSettings
    ) -> TimeInterval {
        let largestLayer = groupedKeys.values.map(\.count).max() ?? 1
        let staggerSpan = Double(max(largestLayer - 1, 0)) * settings.chordStagger
        return duration + staggerSpan + settings.modifierLeadTime + settings.modifierReleaseDelay + 0.006
    }

    private static func keyPressDuration(for group: MappedNoteGroup, settings: PlaybackSettings) -> TimeInterval {
        if settings.holdSustainedNotes {
            let longest = group.events.map(\.duration).max() ?? settings.tapDuration
            return min(max(longest / settings.tempoMultiplier, settings.tapDuration), settings.maxHoldDuration)
        }
        return settings.tapDuration
    }

    private static func dryRunDescription(for group: MappedNoteGroup, settings: PlaybackSettings) -> String {
        group.events.map { event in
            let semitone = positiveModulo(event.adjustedMidiNote - settings.baseMidiNoteForBAS1, 12)
            let noteName = NTELayout.noteNames[semitone]
            if event.pianoKeys.count == 1, let key = event.pianoKeys.first, key.modifier != .none {
                return "\(noteName) -> hold \(key.modifier.displayName), tap \(key.keyboardKey.rawValue)"
            }
            return "\(noteName) -> \(event.keyboardLabel)"
        }
        .joined(separator: "; ")
    }

    private static func keyEventModifier(for modifier: KeyModifier, mode: ModifierInjectionMode) -> KeyModifier {
        switch mode {
        case .hardwareStateLeft, .hardwareStateRight:
            return .none
        case .hybridLeft, .flagsOnly:
            return modifier
        }
    }

    private static func modifierSide(for mode: ModifierInjectionMode) -> ModifierKeySide {
        switch mode {
        case .hardwareStateRight:
            return .right
        case .hardwareStateLeft, .hybridLeft, .flagsOnly:
            return .left
        }
    }

    private static func modifierOrder(_ modifier: KeyModifier) -> Int {
        switch modifier {
        case .none: 0
        case .shift: 1
        case .control: 2
        }
    }

    private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
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
        events: [MappedNoteEvent],
        settings rawSettings: PlaybackSettings,
        injector: KeyInjecting,
        frontmostGuard: @escaping () -> Bool,
        onStateChange: @escaping (PlaybackState) -> Void,
        onProgress: @escaping (TimeInterval) -> Void,
        onFinish: @escaping (PlaybackFinishReason) -> Void
    ) {
        stop()

        let settings = rawSettings.clamped()
        let groupedEvents = EventTimelineBuilder.group(events: events, threshold: settings.chordThreshold)
        let actions = LayeredPlaybackPlanner.plan(groups: groupedEvents, settings: settings)
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
            guard let self else { return }
            self.run(
                runID: runID,
                groups: groupedEvents,
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
            if let pauseBegan {
                pauseDebt += DispatchTime.now().uptimeNanoseconds - pauseBegan
            }
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
        groups: [MappedNoteGroup],
        actions: [ScheduledPlaybackAction],
        settings: PlaybackSettings,
        injector: KeyInjecting,
        frontmostGuard: @escaping () -> Bool,
        onStateChange: @escaping (PlaybackState) -> Void,
        onProgress: @escaping (TimeInterval) -> Void,
        onFinish: @escaping (PlaybackFinishReason) -> Void
    ) {
        let startNanos = DispatchTime.now().uptimeNanoseconds

        if settings.countdownDuration > 0 {
            onStateChange(.countingDown)
        }

        guard !groups.isEmpty else {
            if settings.countdownDuration > 0,
               !wait(until: settings.countdownDuration, startNanos: startNanos, runID: runID) {
                onStateChange(.stopped)
                onFinish(.stopped)
                return
            }
            onStateChange(.playing)
            onStateChange(.completed)
            onFinish(.completed)
            return
        }

        var didEnterPlaying = settings.countdownDuration <= 0
        if didEnterPlaying {
            onStateChange(.playing)
        }

        for action in actions {
            if !didEnterPlaying, action.time >= settings.countdownDuration {
                guard wait(until: settings.countdownDuration, startNanos: startNanos, runID: runID) else {
                    onStateChange(.stopped)
                    onFinish(.stopped)
                    return
                }
                onStateChange(.playing)
                didEnterPlaying = true
            }

            guard wait(until: action.time, startNanos: startNanos, runID: runID) else {
                onStateChange(.stopped)
                onFinish(.stopped)
                return
            }

            let needsFrontmostApp = action.needsFrontmostApp
            if needsFrontmostApp, !frontmostGuard() {
                stop()
                onStateChange(.lostFocus)
                onFinish(.lostFocus)
                return
            }

            switch action.kind {
            case let .key(key, keyEventModifier, keyDown):
                injector.setKey(
                    key,
                    keyEventModifier: keyEventModifier,
                    keyDown: keyDown,
                    eventPostTarget: settings.eventPostTarget
                )
            case let .modifier(modifier, side, keyDown):
                injector.setModifier(
                    modifier,
                    side: side,
                    keyDown: keyDown,
                    eventPostTarget: settings.eventPostTarget
                )
            case let .dryRun(entry):
                injector.recordDryRun(entry)
            case let .progress(time):
                onProgress(time)
            }
        }

        lock.lock()
        let isCurrent = currentRunID == runID && !stopped
        if isCurrent {
            stopped = true
            activeInjector = nil
        }
        lock.unlock()

        if isCurrent {
            injector.releaseAll()
            onStateChange(.completed)
            onFinish(.completed)
        }
    }

    private func wait(until targetSeconds: TimeInterval, startNanos: UInt64, runID: UUID) -> Bool {
        let targetOffset = UInt64(max(0, targetSeconds) * 1_000_000_000)

        while true {
            lock.lock()
            let runIsCurrent = currentRunID == runID
            let shouldStop = stopped || !runIsCurrent
            let isPaused = paused
            let debt = pauseDebt
            lock.unlock()

            if shouldStop { return false }
            if isPaused {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            let target = startNanos + targetOffset + debt
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= target { return true }

            let remaining = TimeInterval(target - now) / 1_000_000_000
            Thread.sleep(forTimeInterval: min(max(remaining, 0.001), 0.005))
        }
    }

}

private extension ScheduledPlaybackAction {
    var needsFrontmostApp: Bool {
        switch kind {
        case .key, .modifier:
            return true
        case .dryRun, .progress:
            return false
        }
    }
}
