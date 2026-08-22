import Foundation

public final class VirtualHIDKeyInjector: KeyInjecting, @unchecked Sendable {
    /// A run stops only after this many consecutive failed sends, so a single transient socket
    /// hiccup (or one lost heartbeat) doesn't abort a whole song.
    private static let maxConsecutiveFailures = 3

    public var previewMode: Bool
    public private(set) var previewLog: [String] = []
    public private(set) var reportTrace: [String] = []
    public var onFailure: ((String) -> Void)?
    /// Fires after a send recovers following one or more failures. Informational only — it
    /// never resumes or restarts playback, it just lets the UI reflect that the bridge is
    /// healthy again.
    public var onRecovered: ((String) -> Void)?

    private let transport: VirtualHIDReportTransport
    private let stateLock = NSLock()
    private let logLock = NSLock()
    private let heartbeatQueue = DispatchQueue(label: "nte-piano-midi-player.virtual-hid.heartbeat")
    private let heartbeatQueueKey = DispatchSpecificKey<Void>()
    private var heartbeatTimer: DispatchSourceTimer?
    private var heldKeyCounts: [KeyboardKey: Int] = [:]
    private var heldModifiers: Set<KeyModifier> = []
    private var failureReported = false
    private var consecutiveFailures = 0
    /// Press order for currently-held keys, used to keep the newest keys when more than
    /// `VirtualHIDConstants.maximumKeys` are held at once instead of failing the report.
    private var pressSequence: UInt64 = 0
    private var heldKeyOrder: [KeyboardKey: UInt64] = [:]

    public init(previewMode: Bool = true, transport: VirtualHIDReportTransport = VirtualHIDSocketClient()) {
        self.previewMode = previewMode
        self.transport = transport
        heartbeatQueue.setSpecific(key: heartbeatQueueKey, value: ())
    }

    deinit {
        stopHeartbeat()
        try? transport.releaseAll()
        transport.disconnect()
    }

    public var connectionStatus: VirtualHIDConnectionStatus { transport.status }

    @discardableResult
    public func refreshConnectionStatus() -> VirtualHIDConnectionStatus {
        transport.refreshStatus()
    }

    public func clearPreviewLog() {
        logLock.lock()
        previewLog.removeAll()
        logLock.unlock()
    }

    public func clearReportTrace() {
        logLock.lock()
        reportTrace.removeAll()
        logLock.unlock()
    }

    public func tapChord(
        _ keys: [PianoKey],
        duration: TimeInterval,
        stagger: TimeInterval,
        modifierMode: ModifierInjectionMode,
        eventPostTarget: EventPostTarget,
        previewDescription: String?
    ) {
        if previewMode {
            recordPreview(previewDescription ?? keys.map(\.keyboardLabel).joined(separator: "+"))
            return
        }
        let grouped = Dictionary(grouping: keys, by: \.modifier)
        for modifier in [KeyModifier.none, .shift, .control] {
            guard let layerKeys = grouped[modifier], !layerKeys.isEmpty else { continue }
            if modifier != .none { setModifier(modifier, side: .left, keyDown: true, eventPostTarget: eventPostTarget) }
            for key in layerKeys {
                setKey(key, keyEventModifier: modifier, keyDown: true, eventPostTarget: eventPostTarget)
                if stagger > 0 { Thread.sleep(forTimeInterval: stagger) }
            }
            if duration > 0 { Thread.sleep(forTimeInterval: duration) }
            for key in layerKeys.reversed() {
                setKey(key, keyEventModifier: modifier, keyDown: false, eventPostTarget: eventPostTarget)
            }
            if modifier != .none { setModifier(modifier, side: .left, keyDown: false, eventPostTarget: eventPostTarget) }
        }
    }

    public func setKey(
        _ key: PianoKey,
        keyEventModifier: KeyModifier,
        keyDown: Bool,
        eventPostTarget: EventPostTarget
    ) {
        guard !previewMode else { return }
        stateLock.lock()
        let count = heldKeyCounts[key.keyboardKey, default: 0]
        let changed: Bool
        if keyDown {
            heldKeyCounts[key.keyboardKey] = count + 1
            changed = count == 0
            if changed {
                pressSequence &+= 1
                heldKeyOrder[key.keyboardKey] = pressSequence
            }
        } else if count > 1 {
            heldKeyCounts[key.keyboardKey] = count - 1
            changed = false
        } else {
            heldKeyCounts.removeValue(forKey: key.keyboardKey)
            heldKeyOrder.removeValue(forKey: key.keyboardKey)
            changed = count == 1
        }
        stateLock.unlock()
        if changed { sendCurrentReport() }
    }

    public func setModifier(
        _ modifier: KeyModifier,
        side: ModifierKeySide,
        keyDown: Bool,
        eventPostTarget: EventPostTarget
    ) {
        guard !previewMode, modifier != .none else { return }
        stateLock.lock()
        let changed: Bool
        if keyDown {
            changed = heldModifiers.insert(modifier).inserted
        } else {
            changed = heldModifiers.remove(modifier) != nil
        }
        stateLock.unlock()
        if changed { sendCurrentReport() }
    }

    public func holdModifier(
        _ modifier: KeyModifier,
        mode: ModifierInjectionMode,
        duration: TimeInterval,
        eventPostTarget: EventPostTarget,
        previewDescription: String?
    ) {
        if previewMode {
            recordPreview(previewDescription ?? "hold \(modifier.displayName)")
            return
        }
        setModifier(modifier, side: .left, keyDown: true, eventPostTarget: eventPostTarget)
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        setModifier(modifier, side: .left, keyDown: false, eventPostTarget: eventPostTarget)
    }

    public func recordPreview(_ entry: String) {
        guard previewMode else { return }
        logLock.lock()
        previewLog.append("PREVIEW \(entry)")
        logLock.unlock()
    }

    public func releaseAll() {
        stateLock.lock()
        heldKeyCounts.removeAll()
        heldKeyOrder.removeAll()
        heldModifiers.removeAll()
        stateLock.unlock()
        stopHeartbeat()
        guard !previewMode else { return }
        do {
            try transport.releaseAll()
            appendTrace("release-all modifiers=none keys=[]")
        } catch {
            reportFailure(error)
        }
    }

    private func sendCurrentReport() {
        let report: VirtualHIDKeyboardReport
        stateLock.lock()
        let allHeldKeys = Array(heldKeyCounts.keys)
        let keys: [KeyboardKey]
        let droppedCount: Int
        if allHeldKeys.count > VirtualHIDConstants.maximumKeys {
            let order = heldKeyOrder
            let newest = allHeldKeys
                .sorted { (order[$0] ?? 0) > (order[$1] ?? 0) }
                .prefix(VirtualHIDConstants.maximumKeys)
            keys = Array(newest).sorted { $0.rawValue < $1.rawValue }
            droppedCount = allHeldKeys.count - keys.count
        } else {
            keys = allHeldKeys.sorted { $0.rawValue < $1.rawValue }
            droppedCount = 0
        }
        var modifiers: VirtualHIDModifiers = []
        if heldModifiers.contains(.shift) { modifiers.insert(.leftShift) }
        if heldModifiers.contains(.control) { modifiers.insert(.leftControl) }
        stateLock.unlock()

        do {
            // `keys` is already capped at VirtualHIDConstants.maximumKeys above, so this can't
            // throw .tooManyKeys.
            report = try VirtualHIDKeyboardReport(modifiers: modifiers, keys: keys.map(\.hidUsage))
            let recoveredOnRetry = try sendReportWithRetry(report)
            handleSendSuccess(recoveredOnRetry: recoveredOnRetry)
            var traceLine = Self.traceLine(for: report, keyboardKeys: keys)
            if droppedCount > 0 { traceLine += " dropped=\(droppedCount) (over the \(VirtualHIDConstants.maximumKeys)-key limit)" }
            appendTrace(traceLine)
            if report.isEmpty { stopHeartbeat() } else { startHeartbeatIfNeeded() }
        } catch {
            stopHeartbeat()
            reportFailure(error)
        }
    }

    /// One retry on send failure — `VirtualHIDSocketClient` reconnects on demand when its
    /// descriptor was closed by a prior error, so this gives a transient socket hiccup a real
    /// chance to recover before it's counted toward the consecutive-failure threshold. Returns
    /// whether the retry was the one that succeeded; throws only when both attempts fail.
    private func sendReportWithRetry(_ report: VirtualHIDKeyboardReport) throws -> Bool {
        do {
            try transport.send(report: report)
            return false
        } catch {
            try transport.send(report: report)
            return true
        }
    }

    private func handleSendSuccess(recoveredOnRetry: Bool) {
        stateLock.lock()
        let hadPriorFailures = consecutiveFailures > 0
        consecutiveFailures = 0
        failureReported = false
        stateLock.unlock()
        guard recoveredOnRetry || hadPriorFailures else { return }
        appendTrace("RECOVERED after a transient VirtualHID failure")
        onRecovered?("The NTE VirtualHID bridge recovered.")
    }

    private func startHeartbeatIfNeeded() {
        heartbeatQueue.sync {
            guard heartbeatTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    try self.transport.sendHeartbeat()
                } catch {
                    // A missed heartbeat alone never stops playback: it's just a keep-alive, and
                    // the next key report will reconnect and restart the heartbeat if the
                    // connection actually dropped.
                    self.stopHeartbeatFromQueue()
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.appendTrace("heartbeat failed, will retry on next report: \(message)")
                }
            }
            heartbeatTimer = timer
            timer.resume()
        }
    }

    private func stopHeartbeat() {
        if DispatchQueue.getSpecific(key: heartbeatQueueKey) != nil {
            stopHeartbeatFromQueue()
        } else {
            heartbeatQueue.sync { stopHeartbeatFromQueue() }
        }
    }

    private func stopHeartbeatFromQueue() {
        heartbeatTimer?.setEventHandler {}
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func reportFailure(_ error: Error) {
        stateLock.lock()
        consecutiveFailures += 1
        let failures = consecutiveFailures
        stateLock.unlock()

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // A single failed send (or one missed retry) doesn't stop playback -- it's logged
        // and the run keeps going, since the very next report often succeeds on its own. Only a
        // run of consecutive failures, or a status that can never self-heal mid-run, is fatal.
        guard failures >= Self.maxConsecutiveFailures || isHardBlockedStatus else {
            appendTrace("WARNING \(message) (attempt \(failures)/\(Self.maxConsecutiveFailures))")
            return
        }

        stateLock.lock()
        let shouldReport = !failureReported
        failureReported = true
        stateLock.unlock()
        guard shouldReport else { return }
        appendTrace("ERROR \(message)")
        onFailure?(message)
    }

    private var isHardBlockedStatus: Bool {
        switch transport.status {
        case .notInstalled, .driverInactive, .versionMismatch:
            true
        default:
            false
        }
    }

    private func appendTrace(_ line: String) {
        logLock.lock()
        reportTrace.append(line)
        if reportTrace.count > 500 { reportTrace.removeFirst(reportTrace.count - 500) }
        logLock.unlock()
    }

    private static func traceLine(for report: VirtualHIDKeyboardReport, keyboardKeys: [KeyboardKey]) -> String {
        var modifierNames: [String] = []
        if report.modifiers.contains(.leftShift) { modifierNames.append("leftShift") }
        if report.modifiers.contains(.leftControl) { modifierNames.append("leftControl") }
        let modifiers = modifierNames.isEmpty ? "none" : modifierNames.joined(separator: "+")
        let keys = keyboardKeys.map(\.rawValue).joined(separator: ",")
        return "report modifiers=\(modifiers) keys=[\(keys)]"
    }
}

public extension KeyboardKey {
    var hidUsage: UInt16 {
        switch self {
        case .a: 0x04
        case .b: 0x05
        case .c: 0x06
        case .d: 0x07
        case .e: 0x08
        case .f: 0x09
        case .g: 0x0A
        case .h: 0x0B
        case .j: 0x0D
        case .m: 0x10
        case .n: 0x11
        case .q: 0x14
        case .r: 0x15
        case .s: 0x16
        case .t: 0x17
        case .u: 0x18
        case .v: 0x19
        case .w: 0x1A
        case .x: 0x1B
        case .y: 0x1C
        case .z: 0x1D
        }
    }
}
