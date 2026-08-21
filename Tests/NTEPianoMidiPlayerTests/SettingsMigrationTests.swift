import XCTest
@testable import NTEPianoMidiPlayerCore

final class SettingsMigrationTests: XCTestCase {
    private let legacySettingsKey = "NTEPianoMidiPlayer.settings.v1"
    private let currentSettingsKey = "NTEPianoMidiPlayer.settings.v2"

    func testLegacyDryRunMigratesToStartupPreviewPreference() throws {
        let legacy = Data(#"{"dryRun":false}"#.utf8)
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: legacy)
        XCTAssertFalse(settings.startInPreviewMode)
        XCTAssertEqual(settings.arrangementMode, .automatic)
    }

    func testNewEncodingUsesPreviewTerminologyOnly() throws {
        let data = try JSONEncoder().encode(PlaybackSettings(startInPreviewMode: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["startInPreviewMode"] as? Bool, true)
        XCTAssertNil(object["dryRun"])
    }

    func testLegacyHardwareStateLeftMigratesOnceToHybridLeftAndRetainsV1Data() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var legacy = PlaybackSettings()
        legacy.layoutMode = .nte21Natural
        legacy.modifierInjectionMode = .hardwareStateLeft
        legacy.modifierLeadTime = 0.234
        legacy.eventPostTarget = .frontmostPid
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: legacySettingsKey)

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.settings.modifierInjectionMode, .hybridLeft)
        XCTAssertEqual(store.settings.layoutMode, .nte21Natural)
        XCTAssertEqual(store.settings.modifierLeadTime, 0.234)
        XCTAssertEqual(store.settings.eventPostTarget, .frontmostPid)
        XCTAssertEqual(defaults.data(forKey: legacySettingsKey), legacyData)
        let migratedData = try XCTUnwrap(defaults.data(forKey: currentSettingsKey))
        let migrated = try JSONDecoder().decode(PlaybackSettings.self, from: migratedData)
        XCTAssertEqual(migrated.modifierInjectionMode, .hybridLeft)
    }

    func testCurrentModifierChoicesAreNeverRemigrated() throws {
        for mode in [ModifierInjectionMode.hardwareStateLeft, .flagsOnly, .hardwareStateRight] {
            let (defaults, suiteName) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var current = PlaybackSettings()
            current.modifierInjectionMode = mode
            defaults.set(try JSONEncoder().encode(current), forKey: currentSettingsKey)

            let store = SettingsStore(defaults: defaults)
            XCTAssertEqual(store.settings.modifierInjectionMode, mode)

            store.settings.modifierInjectionMode = mode
            let reloaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.settings.modifierInjectionMode, mode)
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SettingsMigrationTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
