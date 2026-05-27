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
    private struct LayerSegment {
        var desiredTime: TimeInterval
        var duration: TimeInterval
        var modifier: KeyModifier
        var keys: [PianoKey]
        var progressTime: TimeInterval?
        var dryRunDescription: String
    }

    public static func plan(groups: [MappedNoteGroup], settings rawSettings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        let settings = rawSettings.clamped()
        let segments = makeSegments(groups: groups, settings: settings)
        return planSegments(segments, settings: settings)
    }

    private static func makeSegments(groups: [MappedNoteGroup], settings: PlaybackSettings) -> [LayerSegment] {
        var segments: [LayerSegment] = []

        for group in groups {
            let baseTime = settings.countdownDuration + (group.startTime / settings.tempoMultiplier)
            let duration = keyPressDuration(for: group, settings: settings)
            let groupedKeys = keysByModifier(for: group)
            let activeLayers = [KeyModifier.none, .shift, .control].filter { !(groupedKeys[$0] ?? []).isEmpty }

            for (layerIndex, modifier) in activeLayers.enumerated() {
                guard let keys = groupedKeys[modifier], !keys.isEmpty else { continue }
                segments.append(
                    LayerSegment(
                        desiredTime: baseTime,
                        duration: duration,
                        modifier: modifier,
                        keys: keys,
                        progressTime: layerIndex == 0 ? group.startTime : nil,
                        dryRunDescription: dryRunDescription(for: keys, modifier: modifier)
                    )
                )
            }
        }

        return segments.sorted {
            if $0.desiredTime == $1.desiredTime {
                return modifierOrder($0.modifier) < modifierOrder($1.modifier)
            }
            return $0.desiredTime < $1.desiredTime
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

    private static func planSegments(_ segments: [LayerSegment], settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        var actions: [ScheduledPlaybackAction] = []
        var cursor: TimeInterval = 0
        var index = 0

        while index < segments.count {
            let segment = segments[index]
            if segment.modifier == .none || settings.modifierInjectionMode == .flagsOnly {
                let keyStartTime = max(segment.desiredTime, cursor)
                actions.append(contentsOf: utilityActions(for: segment, at: keyStartTime))
                actions.append(contentsOf: keyActions(for: segment, keyStartTime: keyStartTime, settings: settings))
                cursor = segmentEnd(for: segment, keyStartTime: keyStartTime, settings: settings) + settings.layerSwitchGap
                index += 1
                continue
            }

            let modifier = segment.modifier
            let side = modifierSide(for: settings.modifierInjectionMode)
            let modifierDownTime = max(cursor, segment.desiredTime - settings.modifierLeadTime)
            var runSegments: [(segment: LayerSegment, keyStartTime: TimeInterval)] = []
            var lastKeyUpTime: TimeInterval = 0
            var nextMinimumKeyStart = modifierDownTime + settings.modifierLeadTime
            var runIndex = index

            while runIndex < segments.count {
                let candidate = segments[runIndex]
                guard candidate.modifier == modifier else { break }

                if runIndex != index {
                    let projectedModifierUp = lastKeyUpTime + settings.modifierReleaseDelay
                    guard candidate.desiredTime <= projectedModifierUp + settings.modifierReuseWindow else {
                        break
                    }
                }

                let keyStartTime = max(candidate.desiredTime, nextMinimumKeyStart)
                runSegments.append((candidate, keyStartTime))
                lastKeyUpTime = max(lastKeyUpTime, segmentEnd(for: candidate, keyStartTime: keyStartTime, settings: settings))
                nextMinimumKeyStart = keyStartTime
                runIndex += 1
            }

            actions.append(
                ScheduledPlaybackAction(
                    time: modifierDownTime,
                    order: 10,
                    kind: .modifier(modifier, side, keyDown: true)
                )
            )
            for planned in runSegments {
                actions.append(contentsOf: utilityActions(for: planned.segment, at: planned.keyStartTime))
                actions.append(contentsOf: keyActions(for: planned.segment, keyStartTime: planned.keyStartTime, settings: settings))
            }
            let modifierUpTime = lastKeyUpTime + settings.modifierReleaseDelay
            actions.append(
                ScheduledPlaybackAction(
                    time: modifierUpTime,
                    order: 300,
                    kind: .modifier(modifier, side, keyDown: false)
                )
            )
            cursor = modifierUpTime + settings.layerSwitchGap
            index = runIndex
        }

        return actions.sorted {
            if $0.time == $1.time {
                return $0.order < $1.order
            }
            return $0.time < $1.time
        }
    }

    private static func utilityActions(for segment: LayerSegment, at keyStartTime: TimeInterval) -> [ScheduledPlaybackAction] {
        var actions = [
            ScheduledPlaybackAction(
                time: keyStartTime,
                order: 0,
                kind: .dryRun("\(segment.dryRunDescription) duration=\(String(format: "%.3f", segment.duration))")
            )
        ]
        if let progressTime = segment.progressTime {
            actions.append(
                ScheduledPlaybackAction(
                    time: keyStartTime,
                    order: 900,
                    kind: .progress(progressTime)
                )
            )
        }
        return actions
    }

    private static func keyActions(for segment: LayerSegment, keyStartTime: TimeInterval, settings: PlaybackSettings) -> [ScheduledPlaybackAction] {
        var actions: [ScheduledPlaybackAction] = []
        let keyEventModifier = keyEventModifier(for: segment.modifier, mode: settings.modifierInjectionMode)

        for (index, key) in segment.keys.enumerated() {
            let downTime = keyStartTime + (Double(index) * settings.chordStagger)
            let upTime = downTime + segment.duration
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

    private static func segmentEnd(for segment: LayerSegment, keyStartTime: TimeInterval, settings: PlaybackSettings) -> TimeInterval {
        keyStartTime + (Double(max(segment.keys.count - 1, 0)) * settings.chordStagger) + segment.duration
    }

    private static func keyPressDuration(for group: MappedNoteGroup, settings: PlaybackSettings) -> TimeInterval {
        if settings.holdSustainedNotes {
            let longest = group.events.map(\.duration).max() ?? settings.tapDuration
            return min(max(longest / settings.tempoMultiplier, settings.tapDuration), settings.maxHoldDuration)
        }
        return settings.tapDuration
    }

    private static func dryRunDescription(for keys: [PianoKey], modifier: KeyModifier) -> String {
        let taps = keys.map { "\($0.noteName) tap \($0.keyboardKey.rawValue)" }.joined(separator: ", ")
        switch modifier {
        case .none:
            return "natural -> \(taps)"
        case .shift:
            return "enter Shift layer -> \(taps) -> exit Shift layer"
        case .control:
            return "enter Ctrl layer -> \(taps) -> exit Ctrl layer"
        }
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
