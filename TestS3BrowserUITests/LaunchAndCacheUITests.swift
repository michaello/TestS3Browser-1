import XCTest

@MainActor
final class LaunchAndCacheUITests: XCTestCase {
    private func launch(_ name: String, failure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["S3BROWSER_AUDIT_FIXTURE"] = "1"
        app.launchEnvironment["S3BROWSER_AUDIT_CASE"] = name
        app.launchEnvironment["S3BROWSER_AUDIT_FAILURE"] = failure ? "1" : "0"
        app.launch()
        return app
    }

    private func finish(_ app: XCUIApplication) {
        // The real scene lifecycle flushes the final aggregate before termination.
        XCUIDevice.shared.press(.home)
        app.terminate()
    }

    func testCachedContentPrecedesDelayedRefresh() {
        let app = launch("cache-success")
        let cached = app.descendants(matching: .any)["audit-cache-first.txt"].firstMatch
        XCTAssertTrue(cached.waitForExistence(timeout: 2), "Saved content must appear before the 3-second fixture response")
        let refreshed = app.descendants(matching: .any)["audit-refreshed.txt"].firstMatch
        XCTAssertTrue(refreshed.waitForExistence(timeout: 8))
        finish(app)
    }

    func testOfflineRefreshRetainsSavedContentAndShowsError() {
        let app = launch("offline", failure: true)
        let cached = app.descendants(matching: .any)["audit-cache-first.txt"].firstMatch
        XCTAssertTrue(cached.waitForExistence(timeout: 2))
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "incomplete")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 8))
        XCTAssertTrue(cached.exists)
        finish(app)
    }

    func testScrollingUsesTheRealRecentList() {
        let app = launch("scrolling")
        let cached = app.descendants(matching: .any)["audit-cache-first.txt"].firstMatch
        XCTAssertTrue(cached.waitForExistence(timeout: 2))
        app.swipeUp();app.swipeUp();app.swipeDown()
        XCTAssertTrue(app.buttons["Recent"].exists)
        finish(app)
    }

    func testCustomTabsExposeExactlyOneSelectedAccessibleControl() {
        let app = launch("tab-accessibility")
        let names = ["browse", "apps", "recent", "stash", "stats", "upload", "settings"]
        XCTAssertTrue(app.buttons["tab.recent"].waitForExistence(timeout: 4))
        for selected in names {
            app.buttons["tab." + selected].tap()
            for name in names {
                let button = app.buttons["tab." + name]
                XCTAssertTrue(button.exists)
                XCTAssertFalse(button.label.isEmpty)
                XCTAssertEqual(button.isSelected, name == selected)
            }
        }
        finish(app)
    }

    func testSelectionCanBeCancelledWithoutOpeningOrDeletingAFile() {
        let app = launch("selection", failure: true)
        let cached = app.descendants(matching: .any)["audit-cache-first.txt"].firstMatch
        XCTAssertTrue(cached.waitForExistence(timeout: 2))
        app.buttons["Edit"].tap()
        cached.tap()
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Browse"].tap()
        app.buttons["Recent"].tap()
        XCTAssertTrue(app.buttons["Done"].exists, "A tab revisit preserves the existing selection state")
        app.buttons["Done"].tap()
        XCTAssertTrue(cached.exists)
        finish(app)
    }
}
