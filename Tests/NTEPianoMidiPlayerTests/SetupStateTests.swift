import XCTest
@testable import NTEPianoMidiPlayerCore

final class SetupStateTests: XCTestCase {
    func testSetupStepOrderingMatchesTheLadder() {
        let ordered = SetupStep.allCases.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(ordered, [.installDriver, .activateExtension, .installServices, .grantAccessibility])
    }

    func testTwentyOneKeyModeOnlyBlocksOnAccessibility() {
        // Driver/extension state is irrelevant to 21-key mode, so pass values that would
        // block 36-key mode to prove they're ignored.
        let blocked = SetupInspector.readiness(
            virtualHIDStatus: .notInstalled,
            layoutMode: .nte21Natural,
            accessibilityTrusted: false,
            driverInstalled: false,
            driverExtensionActivated: false
        )
        XCTAssertEqual(blocked.blockingStep, .grantAccessibility)

        let ready = SetupInspector.readiness(
            virtualHIDStatus: .notInstalled,
            layoutMode: .nte21Natural,
            accessibilityTrusted: true,
            driverInstalled: false,
            driverExtensionActivated: false
        )
        XCTAssertTrue(ready.isReady)
    }

    func testThirtySixKeyModeChecksTheLadderInOrder() {
        let missingDriver = SetupInspector.readiness(
            virtualHIDStatus: .ready,
            layoutMode: .nte36Chromatic,
            accessibilityTrusted: true,
            driverInstalled: false,
            driverExtensionActivated: false
        )
        XCTAssertEqual(missingDriver.blockingStep, .installDriver)

        let missingExtension = SetupInspector.readiness(
            virtualHIDStatus: .ready,
            layoutMode: .nte36Chromatic,
            accessibilityTrusted: true,
            driverInstalled: true,
            driverExtensionActivated: false
        )
        XCTAssertEqual(missingExtension.blockingStep, .activateExtension)

        let blockedOnServices = SetupInspector.readiness(
            virtualHIDStatus: .bridgeUnavailable,
            layoutMode: .nte36Chromatic,
            accessibilityTrusted: true,
            driverInstalled: true,
            driverExtensionActivated: true
        )
        XCTAssertEqual(blockedOnServices.blockingStep, .installServices)
        XCTAssertEqual(blockedOnServices.detail, VirtualHIDConnectionStatus.bridgeUnavailable.guidance)

        let ready = SetupInspector.readiness(
            virtualHIDStatus: .ready,
            layoutMode: .nte36Chromatic,
            accessibilityTrusted: false,
            driverInstalled: true,
            driverExtensionActivated: true
        )
        XCTAssertTrue(ready.isReady, "36-key mode does not depend on Accessibility trust.")
    }

    func testReadinessEquatableReadyCase() {
        XCTAssertEqual(SetupReadiness.ready, SetupReadiness.ready)
        XCTAssertNil(SetupReadiness.ready.blockingStep)
        XCTAssertNil(SetupReadiness.ready.detail)
    }
}
