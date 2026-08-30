import XCTest

/// Query Runner smoke test: browse the bundled benchmark catalog, run a
/// benchmark against the synced store, see a result count + timings.
final class QueryRunnerUITests: XCTestCase {

    @MainActor
    func testRunBenchmarkFromCatalog() throws {
        let app = XCUIApplication()
        // Preselect Seattle via the NSUserDefaults argument domain (skips the
        // picker; boot applies the selection and registers per-store subs).
        app.launchArguments = ["-selectedStoreId", "store_seattle"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 60))

        app.tabBars.buttons["Ditto"].tap()
        let runnerRow = app.staticTexts["Query Runner"]
        XCTAssertTrue(runnerRow.waitForExistence(timeout: 30))
        runnerRow.tap()

        // Catalog browser: find the anchor-order point lookup (fast, 1 row).
        // It's in the "orders" section, off-screen — scroll until it renders.
        let entry = app.staticTexts["orders__select__by_id"]
        var scrolled = 0
        while !entry.exists && scrolled < 12 {
            app.swipeUp()
            scrolled += 1
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "orders__select__by_id should appear after scrolling the catalog")
        entry.tap()

        // The detail is a ScrollView (query + pre/post blocks) — the Run
        // button may be below the fold, and AnvilButton surfaces as a Button.
        let run = app.buttons["Run benchmark"].firstMatch
        var detailScrolled = 0
        while !run.exists && detailScrolled < 8 {
            app.swipeUp()
            detailScrolled += 1
        }
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.tap()

        let resultCount = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'rows'"))
            .firstMatch
        XCTAssertTrue(resultCount.waitForExistence(timeout: 60),
                      "the run should report a result count")
        XCTAssertTrue(resultCount.label.contains("1"),
                      "orders__select__by_id hits exactly the anchor order (got: \(resultCount.label))")

        let mean = app.staticTexts["Mean"]
        XCTAssertTrue(mean.waitForExistence(timeout: 10))
    }
}
