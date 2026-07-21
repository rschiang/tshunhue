//
//  TshunhueUITestsLaunchTests.swift
//  TshunhueUITests
//
//  Captures launch-state screenshots across supported UI configurations.
//

import XCTest

/// Launches each target UI configuration and preserves a diagnostic screenshot.
final class TshunhueUITestsLaunchTests: XCTestCase {
    /// Requests a launch run for every target application UI configuration.
    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }

    /// Stops each launch test at its first failed assertion.
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Verifies the launch window and attaches its screenshot to the result bundle.
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
