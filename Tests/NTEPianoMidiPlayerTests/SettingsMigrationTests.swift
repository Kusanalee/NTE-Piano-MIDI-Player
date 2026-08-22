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

    func testDefaultCountdownIsSevenSecondsAndClampsToFifteen() throws {
        XCTAssertEqual(PlaybackSettings().countdownDuration, 7.0)

        var overshoot = PlaybackSettings()
        overshoot.countdownDuration = 999
        XCTAssertEqual(overshoot.clamped().countdownDuration, 15)

        var undershoot = PlaybackSettings()
        undershoot.countdownDuration = -5
        XCTAssertEqual(undershoot.clamped().countdownDuration, 0)
    }

    func testNewOnboardingAndAppearanceFieldsRoundTripThroughCoding() throws {
        var settings = PlaybackSettings()
        settings.advancedSettingsEnabled = true
        settings.glassOpacity = 0.6
        settings.onboardingCompletedVersion = 3

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)

        XCTAssertTrue(decoded.advancedSettingsEnabled)
        XCTAssertEqual(decoded.glassOpacity, 0.6)
        XCTAssertEqual(decoded.onboardingCompletedVersion, 3)
    }

    func testMissingNewFieldsDecodeToSafeDefaults() throws {
        let legacy = Data(#"{"layoutMode":"nte21Natural"}"#.utf8)
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: legacy)

        XCTAssertFalse(settings.advancedSettingsEnabled)
        XCTAssertEqual(settings.glassOpacity, 0.85)
        XCTAssertEqual(settings.onboardingCompletedVersion, 0)
    }

    func testGlassOpacityClampsToItsRange() throws {
        var tooLow = PlaybackSettings()
        tooLow.glassOpacity = 0
        XCTAssertEqual(tooLow.clamped().glassOpacity, 0.35)

        var tooHigh = PlaybackSettings()
        tooHigh.glassOpacity = 5
        XCTAssertEqual(tooHigh.clamped().glassOpacity, 1.0)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SettingsMigrationTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
