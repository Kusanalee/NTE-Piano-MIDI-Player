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
    private let settingsKey = "NTEPianoMidiPlayer.settings.v1"
    private let recentFilesKey = "NTEPianoMidiPlayer.recentFiles.v1"

    public var settingsPublisher: Published<PlaybackSettings>.Publisher { $settings }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.loadSettings(defaults: defaults, key: settingsKey)
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
        defaults.set(encoded, forKey: settingsKey)
    }

    private func saveRecentFiles() {
        let paths = recentFiles.map(\.path)
        defaults.set(paths, forKey: recentFilesKey)
    }

    private static func loadSettings(defaults: UserDefaults, key: String) -> PlaybackSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else {
            return PlaybackSettings()
        }
        return decoded.clamped()
    }

    private static func loadRecentFiles(defaults: UserDefaults, key: String) -> [URL] {
        let paths = defaults.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }
}
