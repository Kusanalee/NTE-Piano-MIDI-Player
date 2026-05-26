import XCTest
@testable import NTEPianoMidiPlayerCore

final class ForegroundAppGuardTests: XCTestCase {
    func testNTEAppNameIsAcceptedByDefault() {
        let defaults = PlaybackSettings().clamped().acceptedForegroundAppNames

        XCTAssertTrue(ForegroundAppGuard.isAccepted(appName: "NTE.app", acceptedNames: defaults))
    }
}
