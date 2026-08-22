import AppKit
import Foundation

public enum PrivilegedServiceInstallError: Error, LocalizedError, Equatable {
    case bridgeNotEmbedded
    case cancelled
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bridgeNotEmbedded:
            "The VirtualHID bridge helper is missing from this app bundle. Reinstall the app."
        case .cancelled:
            "The administrator prompt was cancelled."
        case let .scriptFailed(message):
            message
        }
    }
}

/// Installs and removes the two root LaunchDaemons 36-key playback depends on: Karabiner's
/// own VirtualHID daemon, and this app's bridge helper that relays keyboard reports to it.
///
/// Both are installed with a single administrator prompt (`osascript ... with administrator
/// privileges`) so setup costs the user exactly one password, not one per command. The bridge
/// binary is copied out of the app bundle first — `/Applications` is admin-group writable, so
/// a root LaunchDaemon must never execute a binary directly inside the `.app`.
public enum PrivilegedServiceInstaller {
    public static let bridgeHelperLabel = "dev.enka.NTEPianoMidiPlayer.virtualhid-bridge"
    public static let karabinerDaemonLabel = "org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon"

    public static let installedHelperPath = "/Library/PrivilegedHelperTools/\(bridgeHelperLabel)"
    public static let bridgeDaemonPlistPath = "/Library/LaunchDaemons/\(bridgeHelperLabel).plist"
    public static let karabinerDaemonPlistPath = "/Library/LaunchDaemons/\(karabinerDaemonLabel).plist"

    /// Marks that *we* wrote the Karabiner daemon plist, so uninstall never deletes one that
    /// belongs to a real Karabiner-Elements install.
    private static let karabinerOwnershipMarkerPath =
        "/Library/Application Support/org.pqrs/.installed-by-dev.enka.NTEPianoMidiPlayer"

    private static let karabinerDaemonProgramPath =
        "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"

    /// What the confirmation alert should tell the user before the password prompt.
    public static let installSummary = [
        "Copy the VirtualHID bridge helper to /Library/PrivilegedHelperTools",
        "Install a LaunchDaemon so the bridge starts automatically at login",
        "Install a LaunchDaemon for Karabiner's VirtualHID daemon, only if one isn't already present"
    ]

    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: installedHelperPath)
            && FileManager.default.fileExists(atPath: bridgeDaemonPlistPath)
    }

    public static func embeddedHelperPath() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NTEVirtualHIDBridge")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    public static func embeddedHelperVersion() -> String? {
        embeddedHelperPath().flatMap(runVersion(at:))
    }

    public static func installedHelperVersion() -> String? {
        guard FileManager.default.fileExists(atPath: installedHelperPath) else { return nil }
        return runVersion(at: installedHelperPath)
    }

    /// True when a helper is installed but doesn't match the bundled build — e.g. after an
    /// app update changed the wire protocol. The caller should offer to reinstall.
    public static func isHelperStale() -> Bool {
        guard let installed = installedHelperVersion() else { return false }
        return installed != embeddedHelperVersion()
    }

    /// Copies the bridge into place, writes both LaunchDaemon plists, and bootstraps them
    /// under launchd. Prompts for an administrator password exactly once.
    public static func install(consoleUID: uid_t = getuid()) throws {
        guard let embeddedPath = embeddedHelperPath() else {
            throw PrivilegedServiceInstallError.bridgeNotEmbedded
        }

        var script = "set -e\n"
        script += "mkdir -p /Library/PrivilegedHelperTools\n"
        script += "launchctl bootout system/\(bridgeHelperLabel) 2>/dev/null || true\n"
        script += "ditto \(posixQuote(embeddedPath)) \(posixQuote(installedHelperPath))\n"
        script += "chown root:wheel \(posixQuote(installedHelperPath))\n"
        script += "chmod 755 \(posixQuote(installedHelperPath))\n"

        script += "if [ ! -f \(posixQuote(karabinerDaemonPlistPath)) ]; then\n"
        script += "cat > \(posixQuote(karabinerDaemonPlistPath)) << 'NTE_KARABINER_PLIST'\n"
        script += karabinerDaemonPlistContents
        script += "NTE_KARABINER_PLIST\n"
        script += "chown root:wheel \(posixQuote(karabinerDaemonPlistPath))\n"
        script += "chmod 644 \(posixQuote(karabinerDaemonPlistPath))\n"
        script += "touch \(posixQuote(karabinerOwnershipMarkerPath))\n"
        script += "fi\n"

        script += "cat > \(posixQuote(bridgeDaemonPlistPath)) << 'NTE_BRIDGE_PLIST'\n"
        script += bridgeDaemonPlistContents(consoleUID: consoleUID)
        script += "NTE_BRIDGE_PLIST\n"
        script += "chown root:wheel \(posixQuote(bridgeDaemonPlistPath))\n"
        script += "chmod 644 \(posixQuote(bridgeDaemonPlistPath))\n"

        script += "launchctl bootout system/\(karabinerDaemonLabel) 2>/dev/null || true\n"
        script += "launchctl bootstrap system \(posixQuote(karabinerDaemonPlistPath))\n"
        script += "launchctl bootstrap system \(posixQuote(bridgeDaemonPlistPath))\n"

        try runAsAdministrator(script)
    }

    /// Boots out and removes both LaunchDaemons and the copied helper. Only removes the
    /// Karabiner daemon plist if `install()` is the one that created it.
    public static func uninstall() throws {
        var script = "set -e\n"
        script += "launchctl bootout system/\(bridgeHelperLabel) 2>/dev/null || true\n"
        script += "rm -f \(posixQuote(bridgeDaemonPlistPath))\n"
        script += "rm -f \(posixQuote(installedHelperPath))\n"
        script += "if [ -f \(posixQuote(karabinerOwnershipMarkerPath)) ]; then\n"
        script += "launchctl bootout system/\(karabinerDaemonLabel) 2>/dev/null || true\n"
        script += "rm -f \(posixQuote(karabinerDaemonPlistPath))\n"
        script += "rm -f \(posixQuote(karabinerOwnershipMarkerPath))\n"
        script += "fi\n"

        try runAsAdministrator(script)
    }

    private static var karabinerDaemonPlistContents: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>\(karabinerDaemonLabel)</string>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>ProgramArguments</key>
            <array>
              <string>\(karabinerDaemonProgramPath)</string>
            </array>
          </dict>
        </plist>

        """
    }

    private static func bridgeDaemonPlistContents(consoleUID: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(bridgeHelperLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedHelperPath)</string>
                <string>--allowed-uid</string>
                <string>\(consoleUID)</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>

        """
    }

    private static func runAsAdministrator(_ shellScript: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nte-privileged-install-\(UUID().uuidString).sh")
        try shellScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let appleScriptSource = """
        do shell script "/bin/bash " & quoted form of "\(scriptURL.path)" with administrator privileges
        """
        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            throw PrivilegedServiceInstallError.scriptFailed("Could not construct the installer script.")
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -128 {
                throw PrivilegedServiceInstallError.cancelled
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "The installer script failed."
            throw PrivilegedServiceInstallError.scriptFailed(message)
        }
    }

    private static func runVersion(at path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
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
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func posixQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
