import XCTest

/// Tab tour: visits every screen against the synced 100k dataset — Orders list
/// + detail (two-query), Products + detail (composite-id stock), Customers
/// (25K directory + exact-email lookup), Ditto system views. Exists to prove
/// the screens work on live data; as a side effect it exercises most view code
/// for coverage.
final class TabTourUITests: XCTestCase {
    @MainActor
    func testTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-selectedStoreId", "store_seattle"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 60))

        assertLowStockCard(app: app)

        // --- Orders: list renders, detail shows the two-query line items ---
        app.tabBars.buttons["Orders"].tap()
        let ordersTable = app.collectionViews.firstMatch
        XCTAssertTrue(ordersTable.waitForExistence(timeout: 60))
        let firstOrderCell = ordersTable.cells.firstMatch
        XCTAssertTrue(
            firstOrderCell.waitForExistence(timeout: 120),
            "orders should sync for the selected store"
        )
        firstOrderCell.tap()
        XCTAssertTrue(app.staticTexts["Line items"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap() // back

        // --- Products: catalog renders, detail shows stock/location ---
        app.tabBars.buttons["Products"].tap()
        let productsTable = app.collectionViews.firstMatch
        XCTAssertTrue(productsTable.waitForExistence(timeout: 30))
        let firstProduct = productsTable.cells.firstMatch
        XCTAssertTrue(firstProduct.waitForExistence(timeout: 60))
        firstProduct.tap()
        XCTAssertTrue(app.staticTexts["Stock at this store"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // --- Customers: directory renders; exact-email search finds the
        //     benchmark's anchor customer (proves 25K-directory sync) ---
        app.tabBars.buttons["Customers"].tap()
        let search = app.textFields["Search name, or exact email…"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("john21@example.net")
        let danielle = app.staticTexts["Danielle Johnson"]
        XCTAssertTrue(
            danielle.waitForExistence(timeout: 60),
            "exact-email lookup should find the anchor customer"
        )

        // Dismiss the software keyboard — it covers the tab bar otherwise.
        if app.keyboards.element.exists {
            app.keyboards.buttons["return"].tap()
        }

        tourDittoTab(app: app)
    }

    /// Dashboard low-stock card: Seattle has 64 SKUs under 5 units — badge
    /// and row list must render (regression test for "shows nothing").
    private func assertLowStockCard(app: XCUIApplication) {
        let lowStockBadge = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'under 5 units' OR label == 'No low stock found'")
        ).firstMatch
        XCTAssertTrue(
            lowStockBadge.waitForExistence(timeout: 120),
            "the low-stock card should render a badge (count or empty state)"
        )
        let lowStockRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'left' OR label == 'out'")
        ).firstMatch
        XCTAssertTrue(
            lowStockRow.waitForExistence(timeout: 60),
            "the low-stock card should list the most critical SKUs"
        )
    }

    /// Ditto tab: system views render (sync status, indexes incl. the app's
    /// own zava_* index names).
    private func tourDittoTab(app: XCUIApplication) {
        app.tabBars.buttons["Ditto"].tap()
        let syncStatusRow = app.staticTexts["Sync status"]
        XCTAssertTrue(syncStatusRow.waitForExistence(timeout: 30))
        syncStatusRow.tap()
        XCTAssertTrue(app.navigationBars["Sync status"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let indexesRow = app.staticTexts["Indexes"]
        XCTAssertTrue(indexesRow.waitForExistence(timeout: 30))
        indexesRow.tap()
        XCTAssertTrue(app.navigationBars["Indexes"].waitForExistence(timeout: 30))
        let appIndex = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'zava_orders_store'")
        ).firstMatch
        XCTAssertTrue(
            appIndex.waitForExistence(timeout: 60),
            "the app's own zava_* indexes should be visible in system:indexes"
        )
    }
}
