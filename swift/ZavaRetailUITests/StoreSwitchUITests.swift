import XCTest

/// Store switch regression test: the user reported a "dataset couldn't be
/// read because it's missing" error and stale cross-store data after
/// switching. This drives the real flow and asserts the dashboard recovers
/// for the new store with no error banner. Runs Kirkland (2,975 orders) →
/// Redmond (5,047): any store pair works, but these small ones keep the
/// sync-bounded KPI assertions off the timing edge the Seattle↔Bellevue
/// pair (55K/37K) hit after the Microsoft-data cutover.
final class StoreSwitchUITests: XCTestCase {
    @MainActor
    func testSwitchStoreKirklandToRedmond() {
        let app = XCUIApplication()
        app.launchArguments = ["-selectedStoreId", "store_kirkland"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 60))
        let kpi = app.staticTexts["kpi.orders"]
        XCTAssertTrue(kpi.waitForExistence(timeout: 60))
        // Kirkland's settled value, captured pre-switch: the post-switch
        // recovery must differ from it (stale Kirkland data would ALSO be
        // non-zero — a bare "recovers to non-zero" assertion can't tell
        // recovered from stale).
        let kirklandValue = Int(kpi.label.replacingOccurrences(of: ",", with: "")) ?? -1

        // Switch via the dashboard header switcher.
        let switcher = app.buttons["storeSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 30))
        switcher.tap()
        let redmond = app.buttons["Zava Retail Redmond"]
        XCTAssertTrue(redmond.waitForExistence(timeout: 30))
        redmond.tap()

        // The header switcher shows the new store…
        XCTAssertTrue(
            app.descendants(matching: .any)["Zava Retail Redmond"].waitForExistence(timeout: 30),
            "header should show the new store after switching"
        )

        // …and NO error surface may appear (banner/badge). Give the app a
        // beat to surface any failure.
        let badText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'missing' OR label CONTAINS[c] 'couldn' OR label CONTAINS[c] 'failed'")
        ).firstMatch
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(badText.exists, "unexpected error text after store switch: \(badText.label)")

        // And the KPI recovers for Redmond with REDMOND'S value — the two
        // stores have different order counts in Microsoft's data, so settling
        // on a different non-zero value proves the dashboard isn't showing
        // the old store's snapshot.
        let recovered = NSPredicate { _, _ in
            let value = Int(kpi.label.replacingOccurrences(of: ",", with: "")) ?? -1
            return value > 0 && value != kirklandValue
        }
        let expectation = XCTNSPredicateExpectation(predicate: recovered, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 300),
            .completed,
            "Redmond's orders KPI should recover with its own value after the switch (Kirkland's was \(kirklandValue))"
        )
    }
}
