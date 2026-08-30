import XCTest

/// End-to-end smoke test against the live Big Peer (run after
/// `scripts/load_data.py --size 100k`): store picker shows synced stores,
/// selecting Seattle lands on a dashboard whose KPIs fill in from sync.
final class ZavaRetailUITests: XCTestCase {
    @MainActor
    func testStorePickerToDashboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStoreSelection"]
        app.launch()

        // Store picker: the 8 stores arrive over the shared subscription.
        let pickerNav = app.navigationBars["Choose your store"]
        XCTAssertTrue(pickerNav.waitForExistence(timeout: 60))

        let seattle = app.staticTexts["Zava Retail Seattle"]
        XCTAssertTrue(
            seattle.waitForExistence(timeout: 120),
            "stores collection should sync from Big Peer"
        )
        seattle.tap()

        // Dashboard with the selected store.
        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Zava Retail Seattle"].waitForExistence(timeout: 30))

        // Orders KPI fills in as the per-store subscription syncs (100k slice:
        // ~25K orders for Seattle — the first page lands quickly).
        let kpi = app.staticTexts["kpi.orders"]
        XCTAssertTrue(kpi.waitForExistence(timeout: 60))
        let nonZero = NSPredicate { _, _ in
            Int(kpi.label.replacingOccurrences(of: ",", with: "")) ?? 0 > 0
        }
        let expectation = XCTNSPredicateExpectation(predicate: nonZero, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 300),
            .completed,
            "orders KPI should become non-zero as orders sync"
        )
    }
}
