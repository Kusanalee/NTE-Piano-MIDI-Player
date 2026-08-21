import Darwin
import Foundation

public enum VirtualHIDConstants {
    public static let protocolVersion: UInt16 = 1
    public static let frameSize = 64
    public static let maximumKeys = 6
    public static let expectedPackageVersion = "8.2.0"
    public static let expectedDriverVersion = "1.8.0"
    public static let expectedClientProtocolVersion = 7

    public static func socketPath(uid: uid_t = getuid()) -> String {
        "/var/run/nte-piano-midi-player-\(uid).sock"
    }
}

public enum VirtualHIDCommand: UInt16, Equatable, Sendable {
    case hello = 1
    case status = 2
    case setReport = 3
    case heartbeat = 4
    case releaseAll = 5
    case error = 6
}

public enum VirtualHIDBridgeStatus: UInt32, Equatable, Sendable {
    case unknown = 0
    case ready = 1
    case daemonUnavailable = 2
    case driverInactive = 3
    case driverDisconnected = 4
    case versionMismatch = 5
    case keyboardNotReady = 6
    case protocolError = 7
}

public enum VirtualHIDConnectionStatus: Equatable, Sendable {
    case checking
    case notInstalled
    case bridgeUnavailable
    case daemonUnavailable
    case driverInactive
    case driverDisconnected
    case versionMismatch
    case keyboardNotReady
    case ready
    case protocolError
    case ioError(String)

    public var isReady: Bool { self == .ready }

    public var title: String {
        switch self {
        case .checking: "Checking"
        case .notInstalled: "Not installed"
        case .bridgeUnavailable: "Bridge unavailable"
        case .daemonUnavailable: "Karabiner daemon unavailable"
        case .driverInactive: "Driver inactive"
        case .driverDisconnected: "Driver disconnected"
        case .versionMismatch: "Version mismatch"
        case .keyboardNotReady: "Virtual keyboard not ready"
        case .ready: "Ready"
        case .protocolError: "Protocol error"
        case .ioError: "Connection error"
        }
    }

    public var guidance: String {
        switch self {
        case .checking:
            "Checking the staged VirtualHID bridge."
        case .notInstalled:
            "Install Karabiner DriverKit VirtualHIDDevice \(VirtualHIDConstants.expectedPackageVersion), then activate its system extension."
        case .bridgeUnavailable:
            "Start the Karabiner daemon and NTE VirtualHID bridge with the setup commands below."
        case .daemonUnavailable:
            "The bridge is running, but Karabiner's root daemon is not reachable."
        case .driverInactive:
            "Activate the Karabiner VirtualHID system extension and approve it in System Settings if prompted."
        case .driverDisconnected:
            "The system extension is active but its virtual keyboard is not connected."
        case .versionMismatch:
            "Install the pinned VirtualHID \(VirtualHIDConstants.expectedPackageVersion) package; the bridge expects driver \(VirtualHIDConstants.expectedDriverVersion) and protocol \(VirtualHIDConstants.expectedClientProtocolVersion)."
        case .keyboardNotReady:
            "Wait for the virtual keyboard to initialize, then refresh status."
        case .ready:
            "36-key playback will send letters, left Shift, and left Control through one virtual hardware keyboard."
        case .protocolError:
            "The app and bridge protocol versions do not match. Rebuild both from the same checkout."
        case let .ioError(message):
            message
        }
    }
}

public struct VirtualHIDModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let leftControl = Self(rawValue: 1 << 0)
    public static let leftShift = Self(rawValue: 1 << 1)
    public static let allowedMask: UInt8 = leftControl.rawValue | leftShift.rawValue
}

public struct VirtualHIDKeyboardReport: Equatable, Sendable {
    public var modifiers: VirtualHIDModifiers
    public var keys: [UInt16]

    public init(modifiers: VirtualHIDModifiers = [], keys: [UInt16] = []) throws {
        guard modifiers.rawValue & ~VirtualHIDModifiers.allowedMask == 0 else {
            throw VirtualHIDProtocolError.unsupportedModifiers
        }
        guard keys.count <= VirtualHIDConstants.maximumKeys else {
            throw VirtualHIDProtocolError.tooManyKeys
        }
        guard Set(keys).count == keys.count, !keys.contains(0) else {
            throw VirtualHIDProtocolError.invalidKeys
        }
        self.modifiers = modifiers
        self.keys = keys
    }

    public var isEmpty: Bool { modifiers.isEmpty && keys.isEmpty }
}

public enum VirtualHIDProtocolError: Error, Equatable, LocalizedError {
    case invalidFrameSize
    case invalidMagic
    case unsupportedVersion
    case unsupportedCommand
    case invalidReservedBytes
    case invalidCommandPayload
    case unsupportedModifiers
    case tooManyKeys
    case invalidKeys
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidFrameSize: "VirtualHID frame size is invalid."
        case .invalidMagic: "VirtualHID frame marker is invalid."
        case .unsupportedVersion: "VirtualHID protocol version is unsupported."
        case .unsupportedCommand: "VirtualHID command is unsupported."
        case .invalidReservedBytes: "VirtualHID reserved bytes must be zero."
        case .invalidCommandPayload: "VirtualHID command contains an unexpected keyboard report."
        case .unsupportedModifiers: "VirtualHID report contains unsupported modifiers."
        case .tooManyKeys: "VirtualHID report exceeds the six-key limit."
        case .invalidKeys: "VirtualHID report contains invalid or duplicate keys."
        case .invalidResponse: "VirtualHID bridge returned an invalid response."
        }
    }
}

public struct VirtualHIDFrame: Equatable, Sendable {
    public static let magic: UInt32 = 0x4845_544E // "NTEH" in little-endian byte order.

    public var command: VirtualHIDCommand
    public var sequence: UInt64
    public var status: VirtualHIDBridgeStatus
    public var modifiers: VirtualHIDModifiers
    public var keys: [UInt16]

    public init(
        command: VirtualHIDCommand,
        sequence: UInt64 = 0,
        status: VirtualHIDBridgeStatus = .unknown,
        modifiers: VirtualHIDModifiers = [],
        keys: [UInt16] = []
    ) throws {
        _ = try VirtualHIDKeyboardReport(modifiers: modifiers, keys: keys)
        guard command == .setReport || (modifiers.isEmpty && keys.isEmpty) else {
            throw VirtualHIDProtocolError.invalidCommandPayload
        }
        self.command = command
        self.sequence = sequence
        self.status = status
        self.modifiers = modifiers
        self.keys = keys
    }

    public func encoded() -> Data {
        var bytes = [UInt8](repeating: 0, count: VirtualHIDConstants.frameSize)
        Self.write(Self.magic, to: &bytes, at: 0)
        Self.write(VirtualHIDConstants.protocolVersion, to: &bytes, at: 4)
        Self.write(command.rawValue, to: &bytes, at: 6)
        Self.write(sequence, to: &bytes, at: 8)
        Self.write(status.rawValue, to: &bytes, at: 16)
        bytes[20] = modifiers.rawValue
        bytes[21] = UInt8(keys.count)
        for (index, key) in keys.enumerated() {
            Self.write(key, to: &bytes, at: 24 + (index * 2))
        }
        return Data(bytes)
    }

    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count == VirtualHIDConstants.frameSize else { throw VirtualHIDProtocolError.invalidFrameSize }
        guard Self.readUInt32(bytes, at: 0) == Self.magic else { throw VirtualHIDProtocolError.invalidMagic }
        guard Self.readUInt16(bytes, at: 4) == VirtualHIDConstants.protocolVersion else {
            throw VirtualHIDProtocolError.unsupportedVersion
        }
        guard let command = VirtualHIDCommand(rawValue: Self.readUInt16(bytes, at: 6)) else {
            throw VirtualHIDProtocolError.unsupportedCommand
        }
        guard Self.readUInt16(bytes, at: 22) == 0, bytes[36...].allSatisfy({ $0 == 0 }) else {
            throw VirtualHIDProtocolError.invalidReservedBytes
        }

        let modifier = VirtualHIDModifiers(rawValue: bytes[20])
        guard modifier.rawValue & ~VirtualHIDModifiers.allowedMask == 0 else {
            throw VirtualHIDProtocolError.unsupportedModifiers
        }
        let keyCount = Int(bytes[21])
        guard keyCount <= VirtualHIDConstants.maximumKeys else { throw VirtualHIDProtocolError.tooManyKeys }
        let allKeys = (0..<VirtualHIDConstants.maximumKeys).map { Self.readUInt16(bytes, at: 24 + ($0 * 2)) }
        let keys = Array(allKeys.prefix(keyCount))
        guard allKeys.dropFirst(keyCount).allSatisfy({ $0 == 0 }), Set(keys).count == keys.count, !keys.contains(0) else {
            throw VirtualHIDProtocolError.invalidKeys
        }
        guard command == .setReport || (modifier.isEmpty && keys.isEmpty) else {
            throw VirtualHIDProtocolError.invalidCommandPayload
        }

        self.command = command
        self.sequence = Self.readUInt64(bytes, at: 8)
        self.status = VirtualHIDBridgeStatus(rawValue: Self.readUInt32(bytes, at: 16)) ?? .unknown
        self.modifiers = modifier
        self.keys = keys
    }

    private static func write<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8], at offset: Int) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) { raw in
            for index in raw.indices { bytes[offset + index] = raw[index] }
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(bytes[offset + $1]) << UInt32($1 * 8)) }
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << UInt64($1 * 8)) }
    }
}
