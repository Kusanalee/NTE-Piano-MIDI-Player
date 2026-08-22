import Foundation

/// One step in the ordered setup ladder a fresh install must clear before playback works.
/// `installDriver`, `activateExtension`, and `installServices` only apply to the 36-key
/// VirtualHID path; `grantAccessibility` only applies to the 21-key CGEvent path.
public enum SetupStep: Int, CaseIterable, Sendable {
    case installDriver
    case activateExtension
    case installServices
    case grantAccessibility

    public var title: String {
        switch self {
        case .installDriver: "Install the virtual keyboard driver"
        case .activateExtension: "Approve the system extension"
        case .installServices: "Set up background services"
        case .grantAccessibility: "Grant Accessibility permission"
        }
    }
}

/// The app's combined readiness to play, folding together driver installation, system
/// extension activation, the app's own background services, and Accessibility trust into
/// one value instead of three independently-checked, unordered signals.
public enum SetupReadiness: Equatable, Sendable {
    case blocked(SetupStep, detail: String)
    case ready

    public var isReady: Bool { self == .ready }

    public var blockingStep: SetupStep? {
        if case let .blocked(step, _) = self { return step }
        return nil
    }

    public var detail: String? {
        if case let .blocked(_, detail) = self { return detail }
        return nil
    }
}

/// Read-only detection for each setup step. Every check here is safe to call from a
/// background queue and does not require the VirtualHID bridge to already be running,
/// which is what lets onboarding tell "not installed" apart from "installed but the
/// system extension was never approved" instead of collapsing both into one vague
/// "bridge unavailable" message.
public enum SetupInspector {
    /// Shared by the standalone Karabiner-DriverKit-VirtualHIDDevice package and by a
    /// full Karabiner-Elements install, so this one path covers both.
    public static let driverInfoPlistPath =
        "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Info.plist"
    public static let driverExtensionBundleID = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"

    public static func installedDriverVersion() -> String? {
        guard let info = NSDictionary(contentsOfFile: driverInfoPlistPath) else { return nil }
        return info["CFBundleVersion"] as? String
    }

    public static var isDriverInstalled: Bool {
        installedDriverVersion() != nil
    }

    public static func isDriverExtensionActivated() -> Bool {
        guard let output = run("/usr/bin/systemextensionsctl", ["list"]) else { return false }
        return output.split(separator: "\n").contains { line in
            line.contains(driverExtensionBundleID) && line.contains("[activated enabled]")
        }
    }

    /// Folds every signal into one ordered readiness value. `virtualHIDStatus` should come
    /// from a fresh `VirtualHIDKeyInjector.refreshConnectionStatus()` call. Reads live driver
    /// and system-extension state; see the fully-injected overload below for tests.
    public static func readiness(
        virtualHIDStatus: VirtualHIDConnectionStatus,
        layoutMode: LayoutMode,
        accessibilityTrusted: Bool
    ) -> SetupReadiness {
        readiness(
            virtualHIDStatus: virtualHIDStatus,
            layoutMode: layoutMode,
            accessibilityTrusted: accessibilityTrusted,
            driverInstalled: isDriverInstalled,
            driverExtensionActivated: isDriverExtensionActivated()
        )
    }

    /// Same ladder, with every live signal passed in explicitly instead of read from the
    /// host machine \u{2014} what tests should call so results don't depend on whether the
    /// machine running them happens to have Karabiner installed.
    public static func readiness(
        virtualHIDStatus: VirtualHIDConnectionStatus,
        layoutMode: LayoutMode,
        accessibilityTrusted: Bool,
        driverInstalled: Bool,
        driverExtensionActivated: Bool
    ) -> SetupReadiness {
        switch layoutMode {
        case .nte21Natural:
            guard accessibilityTrusted else {
                return .blocked(
                    .grantAccessibility,
                    detail: "Grant Accessibility permission so NTE Piano MIDI Player can send keyboard events."
                )
            }
            return .ready
        case .nte36Chromatic:
            guard driverInstalled else {
                return .blocked(
                    .installDriver,
                    detail: "Install Karabiner DriverKit VirtualHIDDevice \(VirtualHIDConstants.expectedPackageVersion) or a compatible Karabiner-Elements build."
                )
            }
            guard driverExtensionActivated else {
                return .blocked(
                    .activateExtension,
                    detail: "Approve the driver extension in System Settings \u{203A} General \u{203A} Login Items & Extensions \u{203A} Driver Extensions."
                )
            }
            guard virtualHIDStatus.isReady else {
                return .blocked(.installServices, detail: virtualHIDStatus.guidance)
            }
            return .ready
        }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
