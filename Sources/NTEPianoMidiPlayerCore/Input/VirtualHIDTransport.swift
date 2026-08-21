import Darwin
import Foundation

public enum VirtualHIDTransportError: Error, LocalizedError {
    case notReady(VirtualHIDConnectionStatus)
    case socket(String)
    case connectionClosed
    case invalidAcknowledgement

    public var errorDescription: String? {
        switch self {
        case let .notReady(status): status.guidance
        case let .socket(message): message
        case .connectionClosed: "The NTE VirtualHID bridge closed the connection."
        case .invalidAcknowledgement: "The NTE VirtualHID bridge returned an invalid acknowledgement."
        }
    }
}

public protocol VirtualHIDReportTransport: AnyObject {
    var status: VirtualHIDConnectionStatus { get }
    @discardableResult func refreshStatus() -> VirtualHIDConnectionStatus
    func send(report: VirtualHIDKeyboardReport) throws
    func sendHeartbeat() throws
    func releaseAll() throws
    func disconnect()
}

public final class VirtualHIDSocketClient: VirtualHIDReportTransport, @unchecked Sendable {
    public static let managerPath = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app"
    public static let supportPath = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice"

    private let socketPath: String
    private let fileManager: FileManager
    private let ioQueue = DispatchQueue(label: "nte-piano-midi-player.virtual-hid.socket", qos: .userInteractive)
    private let stateLock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var nextSequence: UInt64 = 1
    private var storedStatus: VirtualHIDConnectionStatus = .checking

    public init(
        socketPath: String = VirtualHIDConstants.socketPath(),
        fileManager: FileManager = .default
    ) {
        self.socketPath = socketPath
        self.fileManager = fileManager
    }

    deinit {
        disconnect()
    }

    public var status: VirtualHIDConnectionStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedStatus
    }

    @discardableResult
    public func refreshStatus() -> VirtualHIDConnectionStatus {
        ioQueue.sync {
            guard dependencyInstalled else {
                closeSocket()
                return updateStatus(.notInstalled)
            }
            do {
                try connectIfNeeded()
                let request = try VirtualHIDFrame(command: .status)
                let response = try exchange(request)
                return updateStatus(Self.connectionStatus(for: response.status))
            } catch {
                closeSocket()
                return updateStatus(connectionFailureStatus(for: error))
            }
        }
    }

    public func send(report: VirtualHIDKeyboardReport) throws {
        try ioQueue.sync {
            try requireReadyConnection()
            let frame = try VirtualHIDFrame(
                command: .setReport,
                sequence: consumeSequence(),
                modifiers: report.modifiers,
                keys: report.keys
            )
            try requireReadyAcknowledgement(exchange(frame))
        }
    }

    public func sendHeartbeat() throws {
        try ioQueue.sync {
            try requireReadyConnection()
            let frame = try VirtualHIDFrame(command: .heartbeat, sequence: consumeSequence())
            try requireReadyAcknowledgement(exchange(frame))
        }
    }

    public func releaseAll() throws {
        try ioQueue.sync {
            guard fileDescriptor >= 0 else { return }
            let frame = try VirtualHIDFrame(command: .releaseAll, sequence: consumeSequence())
            _ = try? exchange(frame)
        }
    }

    public func disconnect() {
        ioQueue.sync {
            closeSocket()
        }
    }

    private var dependencyInstalled: Bool {
        fileManager.fileExists(atPath: Self.managerPath) || fileManager.fileExists(atPath: Self.supportPath)
    }

    private func requireReadyConnection() throws {
        if fileDescriptor < 0 {
            let refreshed = refreshStatusOnQueue()
            guard refreshed.isReady else { throw VirtualHIDTransportError.notReady(refreshed) }
        }
        guard status.isReady else { throw VirtualHIDTransportError.notReady(status) }
    }

    private func refreshStatusOnQueue() -> VirtualHIDConnectionStatus {
        guard dependencyInstalled else { return updateStatus(.notInstalled) }
        do {
            try connectIfNeeded()
            let response = try exchange(VirtualHIDFrame(command: .status))
            return updateStatus(Self.connectionStatus(for: response.status))
        } catch {
            closeSocket()
            return updateStatus(connectionFailureStatus(for: error))
        }
    }

    private func connectIfNeeded() throws {
        guard fileDescriptor < 0 else { return }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("Could not create the VirtualHID socket") }

        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard utf8.count < capacity else {
            Darwin.close(descriptor)
            throw VirtualHIDTransportError.socket("VirtualHID socket path is too long.")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                for index in 0..<capacity { chars[index] = 0 }
                for (index, byte) in utf8.enumerated() { chars[index] = CChar(bitPattern: byte) }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw socketError("Could not connect to the NTE VirtualHID bridge")
        }
        fileDescriptor = descriptor
        nextSequence = 1

        let response = try exchange(VirtualHIDFrame(command: .hello))
        let connectionStatus = Self.connectionStatus(for: response.status)
        updateStatus(connectionStatus)
    }

    private func exchange(_ frame: VirtualHIDFrame) throws -> VirtualHIDFrame {
        let payload = frame.encoded()
        try writeAll(payload)
        let response = try readExactly(VirtualHIDConstants.frameSize)
        let decoded = try VirtualHIDFrame(decoding: response)
        guard decoded.command == .status || decoded.command == .error,
              decoded.sequence == frame.sequence else {
            throw VirtualHIDTransportError.invalidAcknowledgement
        }
        if decoded.command == .error {
            updateStatus(.protocolError)
            throw VirtualHIDTransportError.invalidAcknowledgement
        }
        updateStatus(Self.connectionStatus(for: decoded.status))
        return decoded
    }

    private func requireReadyAcknowledgement(_ frame: VirtualHIDFrame) throws {
        let connectionStatus = Self.connectionStatus(for: frame.status)
        guard connectionStatus.isReady else {
            throw VirtualHIDTransportError.notReady(connectionStatus)
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.write(fileDescriptor, baseAddress.advanced(by: sent), rawBuffer.count - sent)
                guard result > 0 else {
                    closeSocket()
                    let error = socketError("Could not write to the NTE VirtualHID bridge")
                    updateStatus(.bridgeUnavailable)
                    throw error
                }
                sent += result
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress!.advanced(by: received), count - received)
            }
            guard result > 0 else {
                closeSocket()
                updateStatus(.bridgeUnavailable)
                throw VirtualHIDTransportError.connectionClosed
            }
            received += result
        }
        return Data(bytes)
    }

    private func consumeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    @discardableResult
    private func updateStatus(_ status: VirtualHIDConnectionStatus) -> VirtualHIDConnectionStatus {
        stateLock.lock()
        storedStatus = status
        stateLock.unlock()
        return status
    }

    private func closeSocket() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func socketError(_ prefix: String) -> VirtualHIDTransportError {
        let message = String(cString: strerror(errno))
        return .socket("\(prefix): \(message)")
    }

    private func connectionFailureStatus(for error: Error) -> VirtualHIDConnectionStatus {
        if status == .protocolError { return .protocolError }
        if let protocolError = error as? VirtualHIDProtocolError {
            switch protocolError {
            case .unsupportedVersion, .unsupportedCommand, .invalidMagic, .invalidCommandPayload:
                return .protocolError
            default:
                break
            }
        }
        return .bridgeUnavailable
    }

    private static func connectionStatus(for status: VirtualHIDBridgeStatus) -> VirtualHIDConnectionStatus {
        switch status {
        case .unknown: .checking
        case .ready: .ready
        case .daemonUnavailable: .daemonUnavailable
        case .driverInactive: .driverInactive
        case .driverDisconnected: .driverDisconnected
        case .versionMismatch: .versionMismatch
        case .keyboardNotReady: .keyboardNotReady
        case .protocolError: .protocolError
        }
    }
}
