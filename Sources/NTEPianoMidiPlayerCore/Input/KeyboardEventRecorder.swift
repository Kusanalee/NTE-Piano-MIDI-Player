import CoreGraphics
import Foundation

public enum KeyboardEventDiagnostics {
    /// "NTEP" encoded as an integer. Attached to every event emitted by this app.
    public static let injectedEventMarker: Int64 = 0x4E_54_45_50
}

public struct RecordedKeyboardEvent: Equatable, Identifiable {
    public enum Origin: String {
        case player = "PLAYER"
        case external = "EXTERNAL"
    }

    public let id: Int
    public let timestamp: CGEventTimestamp
    public let type: CGEventType
    public let keyCode: CGKeyCode
    public let flagsRawValue: UInt64
    public let sourcePID: Int64
    public let sourceStateID: Int64
    public let sourceUserData: Int64
    public let isAutorepeat: Bool

    public var origin: Origin {
        sourceUserData == KeyboardEventDiagnostics.injectedEventMarker ? .player : .external
    }

    public var keyLabel: String {
        Self.keyLabels[keyCode] ?? "Key\(keyCode)"
    }

    public var typeLabel: String {
        switch type {
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        case .flagsChanged: "flagsChanged"
        default: "type\(type.rawValue)"
        }
    }

    public var flagsLabel: String {
        let flags = CGEventFlags(rawValue: flagsRawValue)
        var labels: [String] = []
        if flags.contains(.maskShift) { labels.append("shift") }
        if flags.contains(.maskControl) { labels.append("control") }
        if flags.contains(.maskAlternate) { labels.append("option") }
        if flags.contains(.maskCommand) { labels.append("command") }
        if flags.contains(.maskAlphaShift) { labels.append("capsLock") }
        return labels.isEmpty ? "none" : labels.joined(separator: "+")
    }

    public func traceLine(relativeTo firstTimestamp: CGEventTimestamp) -> String {
        let elapsedMilliseconds = Double(timestamp &- firstTimestamp) / 1_000_000
        return String(
            format: "%04d +%9.3fms %-8@ %-12@ key=%-10@ code=%02d flags=%-14@ raw=0x%08llx pid=%lld state=%lld repeat=%d",
            id,
            elapsedMilliseconds,
            origin.rawValue as NSString,
            typeLabel as NSString,
            keyLabel as NSString,
            keyCode,
            flagsLabel as NSString,
            flagsRawValue,
            sourcePID,
            sourceStateID,
            isAutorepeat ? 1 : 0
        )
    }

    init(id: Int, eventType: CGEventType, event: CGEvent) {
        self.id = id
        self.timestamp = event.timestamp
        self.type = eventType
        self.keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        self.flagsRawValue = event.flags.rawValue
        self.sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        self.sourceStateID = event.getIntegerValueField(.eventSourceStateID)
        self.sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        self.isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }

    private static let keyLabels: [CGKeyCode: String] = {
        var labels = Dictionary(uniqueKeysWithValues: KeyboardKey.allCases.map {
            (MacVirtualKeyCodes.code(for: $0), $0.rawValue)
        })
        labels[56] = "LeftShift"
        labels[60] = "RightShift"
        labels[59] = "LeftCtrl"
        labels[62] = "RightCtrl"
        return labels
    }()
}

public final class KeyboardEventRecorder {
    public typealias EventHandler = (RecordedKeyboardEvent) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var nextID = 1
    private var handler: EventHandler?

    public init() {}

    deinit {
        stop()
    }

    @discardableResult
    public func start(handler: @escaping EventHandler) -> Bool {
        stop()
        self.handler = handler
        nextID = 1

        let mask = Self.monitoredTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            // Accessibility already authorizes the app's playback injection. Using
            // a non-listen-only tap avoids requiring a second, unstable TCC identity
            // under Input Monitoring. The callback always returns the original event.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardEventRecorderCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        handler = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        guard Self.relevantKeyCodes.contains(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))) else {
            return
        }
        let record = RecordedKeyboardEvent(id: nextID, eventType: type, event: event)
        nextID += 1
        handler?(record)
    }

    private static let monitoredTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
    private static let relevantKeyCodes: Set<CGKeyCode> = {
        var codes = Set(KeyboardKey.allCases.map { MacVirtualKeyCodes.code(for: $0) })
        codes.formUnion([56, 60, 59, 62])
        return codes
    }()
}

private let keyboardEventRecorderCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<KeyboardEventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
