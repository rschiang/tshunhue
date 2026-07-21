//
//  TshunhueUITests.swift
//  TshunhueUITests
//
//  Contains basic launch and performance coverage for the application UI.
//

import XCTest

/// Smoke and launch-performance tests for Tshunhue's primary window.
final class TshunhueUITests: XCTestCase {
    /// Stops each UI test at its first failed assertion.
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Verifies that launch presents an application window.
    @MainActor
    func testLaunchesIntoSearchExperience() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    /// Measures repeated application launch performance.
    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
