import ApplicationServices
import AppKit
import Foundation

public enum AccessibilityPermission {
    public static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

public final class ForegroundAppGuard {
    public var acceptedNames: [String]

    public init(acceptedNames: [String]) {
        self.acceptedNames = acceptedNames
    }

    public func isAcceptedFrontmostApp() -> Bool {
        guard let name = NSWorkspace.shared.frontmostApplication?.localizedName else {
            return false
        }
        return Self.isAccepted(appName: name, acceptedNames: acceptedNames)
    }

    public static func isAccepted(appName: String, acceptedNames: [String]) -> Bool {
        let normalizedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAppName.isEmpty else { return false }
        return acceptedNames.contains { candidate in
            let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedCandidate.isEmpty else { return false }
            return normalizedAppName == normalizedCandidate || normalizedAppName.contains(normalizedCandidate)
        }
    }
}
