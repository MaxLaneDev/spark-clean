//
//  SparkCleanUITests.swift
//  SparkCleanUITests
//
//  Created by George Khananaev on 3/6/26.
//

import XCTest

final class SparkCleanUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func configuredApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hasCompletedOnboarding", "YES",
            "-showIntroVideo", "NO",
        ]
        return app
    }

    @MainActor
    func testDashboardLaunchesReadyToScan() throws {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "SparkClean did not create its main window."
        )
        XCTAssertTrue(
            app.staticTexts["SparkClean"].waitForExistence(timeout: 10),
            "The dashboard header did not appear."
        )
        XCTAssertTrue(
            app.buttons["Scan"].waitForExistence(timeout: 5),
            "The dashboard Scan action is unavailable."
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            configuredApplication().launch()
        }
    }
}
