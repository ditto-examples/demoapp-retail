import XCTest

/// End-to-end smoke test against the live Big Peer (run after
/// `scripts/load_data.py`, which loads the full transformed Microsoft
/// dataset): first launch SKIPS the store picker — the app auto-selects the
/// store the loader flagged `demo_default` (the fewest orders: Kirkland,
/// 2,975) and lands straight on its dashboard, whose KPIs fill in from sync.
/// The picker stays reachable via the Ditto tab → Switch store.
final class ZavaRetailUITests: XCTestCase {
    @MainActor
    func testFirstLaunchAutoSelectsDefaultStore() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStoreSelection"]
        app.launch()

        // No picker step: with a persisted selection cleared, the store
        // catalog syncs in over the shared subscription and the loader-flagged
        // smallest store is selected automatically (possibly after a brief
        // "Preparing your store…" while the catalog arrives).
        let pickerNav = app.navigationBars["Choose your store"]
        XCTAssertFalse(
            pickerNav.waitForExistence(timeout: 10),
            "first launch must NOT show the store picker — the smallest store is the default"
        )

        // Dashboard for the flagged store (Kirkland: fewest orders).
        _ = app.webViews.firstMatch // keep webviews out of queries
        XCTAssertFalse(app.descendants(matching: .any)["Zava Retail"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["Zava Retail Kirkland"].waitForExistence(timeout: 120),
            "the loader-flagged smallest store (Kirkland) should become the header store"
        )

        // The picker is still reachable on demand (Ditto tab → Switch store),
        // and picking Redmond there takes over cleanly. (Redmond, not
        // Seattle: 5,047 orders vs 54,995 — the KPI assertion isn't about
        // sync-throughput of the biggest store, it just needs *some* orders;
        // Seattle-sized syncs turned this into a timing flake.)
        app.tabBars.buttons["Ditto"].tap()
        let switchRow = app.buttons["Switch store"]
        XCTAssertTrue(switchRow.waitForExistence(timeout: 30))
        switchRow.tap()
        XCTAssertTrue(pickerNav.waitForExistence(timeout: 30))
        let redmond = app.staticTexts["Zava Retail Redmond"]
        XCTAssertTrue(redmond.waitForExistence(timeout: 30), "stores should list in the on-demand picker")
        redmond.tap()

        // Dashboard lands on Redmond and its orders KPI fills in as the
        // per-store subscription syncs (the first page lands quickly).
        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any)["Zava Retail Redmond"].waitForExistence(timeout: 30)
        )
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
