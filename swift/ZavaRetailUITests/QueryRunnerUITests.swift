import XCTest

/// Query Runner smoke test: browse the bundled benchmark catalog, run a
/// benchmark against the synced store, see a result count + timings.
///
/// Runs `customers__select__by_id` (anchor: `customer_40000` — a real
/// Microsoft row). Customers reach the device via the SHARED (unfiltered)
/// subscription, so the anchor is present quickly regardless of which store
/// is selected — unlike the per-store `orders__select__by_id` anchor
/// (`order_197663` is a Seattle order; a Kirkland-first device ecountering
/// 55K Seattle orders mid-sync was the flake source).
final class QueryRunnerUITests: XCTestCase {
    @MainActor
    func testRunBenchmarkFromCatalog() {
        let app = XCUIApplication()
        // Preselect the loader-default (Kirkland — lightest sync) via the
        // NSUserDefaults argument domain (skips the picker).
        app.launchArguments = ["-selectedStoreId", "store_kirkland"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 60))

        app.tabBars.buttons["Ditto"].tap()
        let runnerRow = app.staticTexts["Query Runner"]
        XCTAssertTrue(runnerRow.waitForExistence(timeout: 30))
        runnerRow.tap()

        // Catalog browser: find the anchor point lookup (fast, 1 row).
        // It's in the "customers" section, off-screen — scroll until it renders.
        let entry = app.staticTexts["customers__select__by_id"]
        var scrolled = 0
        while !entry.exists && scrolled < 12 {
            app.swipeUp()
            scrolled += 1
        }
        XCTAssertTrue(
            entry.waitForExistence(timeout: 10),
            "customers__select__by_id should appear after scrolling the catalog"
        )
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
        XCTAssertTrue(
            resultCount.waitForExistence(timeout: 60),
            "the run should report a result count"
        )
        XCTAssertEqual(
            resultCount.label, "1 rows",
            "customers__select__by_id hits exactly the anchor customer (got: \(resultCount.label))"
        )

        let mean = app.staticTexts["Mean"]
        XCTAssertTrue(mean.waitForExistence(timeout: 10))
    }
}
