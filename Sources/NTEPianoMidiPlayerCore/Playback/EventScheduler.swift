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
            guard wait(until: settings.countdownDuration, startNanos: startNanos, runID: runID) else {
                onStateChange(.stopped)
                onFinish(.stopped)
                return
            }
        }

        onStateChange(.playing)
        guard !groups.isEmpty else {
            onStateChange(.completed)
            onFinish(.completed)
            return
        }

        for group in groups {
            let scheduledTime = settings.countdownDuration + (group.startTime / settings.tempoMultiplier)
            guard wait(until: scheduledTime, startNanos: startNanos, runID: runID) else {
                onStateChange(.stopped)
                onFinish(.stopped)
                return
            }
            guard frontmostGuard() else {
                stop()
                onStateChange(.lostFocus)
                onFinish(.lostFocus)
                return
            }

            let duration = keyPressDuration(for: group, settings: settings)
            let keys = group.events.flatMap(\.pianoKeys)
            injector.tapChord(
                keys,
                duration: duration,
                stagger: settings.chordStagger,
                modifierMode: settings.modifierInjectionMode,
                modifierLeadTime: settings.modifierLeadTime,
                modifierReleaseDelay: settings.modifierReleaseDelay,
                dryRunDescription: dryRunDescription(for: group, settings: settings)
            )
            onProgress(group.startTime)
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

    private func keyPressDuration(for group: MappedNoteGroup, settings: PlaybackSettings) -> TimeInterval {
        if settings.holdSustainedNotes {
            let longest = group.events.map(\.duration).max() ?? settings.tapDuration
            return min(max(longest / settings.tempoMultiplier, settings.tapDuration), settings.maxHoldDuration)
        }
        return settings.tapDuration
    }

    private func dryRunDescription(for group: MappedNoteGroup, settings: PlaybackSettings) -> String {
        group.events.map { event in
            let semitone = positiveModulo(event.adjustedMidiNote - settings.baseMidiNoteForBAS1, 12)
            let noteName = NTELayout.noteNames[semitone]
            return "\(noteName) -> \(event.keyboardLabel)"
        }
        .joined(separator: "; ")
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

    private func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
