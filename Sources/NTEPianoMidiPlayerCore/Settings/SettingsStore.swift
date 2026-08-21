import Combine
import Foundation

public final class SettingsStore: ObservableObject {
    @Published public var settings: PlaybackSettings {
        didSet { save() }
    }

    @Published public var recentFiles: [URL] {
        didSet { saveRecentFiles() }
    }

    private let defaults: UserDefaults
    private static let settingsKey = "NTEPianoMidiPlayer.settings.v2"
    private static let legacySettingsKey = "NTEPianoMidiPlayer.settings.v1"
    private let recentFilesKey = "NTEPianoMidiPlayer.recentFiles.v1"

    public var settingsPublisher: Published<PlaybackSettings>.Publisher { $settings }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.loadSettings(defaults: defaults)
        self.recentFiles = Self.loadRecentFiles(defaults: defaults, key: recentFilesKey)
    }

    public func resetSettings() {
        settings = PlaybackSettings()
    }

    public func rememberFile(_ url: URL) {
        var next = recentFiles.filter { $0 != url }
        next.insert(url, at: 0)
        recentFiles = Array(next.prefix(12))
    }

    private func save() {
        let encoded = try? JSONEncoder().encode(settings.clamped())
        defaults.set(encoded, forKey: Self.settingsKey)
    }

    private func saveRecentFiles() {
        let paths = recentFiles.map(\.path)
        defaults.set(paths, forKey: recentFilesKey)
    }

    private static func loadSettings(defaults: UserDefaults) -> PlaybackSettings {
        if let current = decodeSettings(defaults.data(forKey: settingsKey)) {
            return current.clamped()
        }

        var migrated = decodeSettings(defaults.data(forKey: legacySettingsKey)) ?? PlaybackSettings()
        if migrated.modifierInjectionMode == .hardwareStateLeft {
            migrated.modifierInjectionMode = .hybridLeft
        }
        migrated = migrated.clamped()
        if let encoded = try? JSONEncoder().encode(migrated) {
            defaults.set(encoded, forKey: settingsKey)
        }
        return migrated
    }

    private static func decodeSettings(_ data: Data?) -> PlaybackSettings? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(PlaybackSettings.self, from: data)
    }

    private static func loadRecentFiles(defaults: UserDefaults, key: String) -> [URL] {
        let paths = defaults.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }
}
