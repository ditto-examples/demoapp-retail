import XCTest

/// Store switch regression test: the user reported a "dataset couldn't be
/// read because it's missing" error and stale cross-store data after
/// switching. This drives the real flow and asserts the dashboard recovers
/// for the new store with no error banner.
final class StoreSwitchUITests: XCTestCase {
    @MainActor
    func testSwitchStoreSeattleToBellevue() {
        let app = XCUIApplication()
        app.launchArguments = ["-selectedStoreId", "store_seattle"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 60))
        let kpi = app.staticTexts["kpi.orders"]
        XCTAssertTrue(kpi.waitForExistence(timeout: 60))
        // Seattle's settled value, captured pre-switch: the post-switch
        // recovery must differ from it (stale Seattle data would ALSO be
        // non-zero — a bare "recovers to non-zero" assertion can't tell
        // recovered from stale).
        let seattleValue = Int(kpi.label.replacingOccurrences(of: ",", with: "")) ?? -1

        // Switch via the dashboard header switcher.
        let switcher = app.buttons["storeSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 30))
        switcher.tap()
        let bellevue = app.buttons["Zava Retail Bellevue"]
        XCTAssertTrue(bellevue.waitForExistence(timeout: 30))
        bellevue.tap()

        // The header switcher shows the new store…
        XCTAssertTrue(
            app.descendants(matching: .any)["Zava Retail Bellevue"].waitForExistence(timeout: 30),
            "header should show the new store after switching"
        )

        // …and NO error surface may appear (banner/badge). Give the app a
        // beat to surface any failure.
        let badText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'missing' OR label CONTAINS[c] 'couldn' OR label CONTAINS[c] 'failed'")
        ).firstMatch
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(badText.exists, "unexpected error text after store switch: \(badText.label)")

        // And the KPI recovers for Bellevue with BELLEVUE'S value — the two
        // stores have different order counts on the 100k slice, so settling
        // on a different non-zero value proves the dashboard isn't showing
        // the old store's snapshot.
        let recovered = NSPredicate { _, _ in
            let value = Int(kpi.label.replacingOccurrences(of: ",", with: "")) ?? -1
            return value > 0 && value != seattleValue
        }
        let expectation = XCTNSPredicateExpectation(predicate: recovered, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 300),
            .completed,
            "Bellevue's orders KPI should recover with its own value after the switch (Seattle's was \(seattleValue))"
        )
    }
}
