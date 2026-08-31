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

        // Trend table has column headers; top products resolve NAMES from the
        // synced catalog (regression: raw ids like prod_ele_0022 rendered).
        assertTrendHeadersAndProductNames(app: app)

        // KPI values must render on ONE line (regression: the revenue figure
        // bled to a second line). Two .title lines are ~70pt tall; one is ~34.
        let revenue = app.staticTexts["kpi.revenue"]
        XCTAssertTrue(revenue.waitForExistence(timeout: 60))
        XCTAssertLessThanOrEqual(
            revenue.frame.height, 45,
            "revenue KPI wrapped to multiple lines (frame height \(revenue.frame.height))"
        )

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
        var lowScrolled = 0
        while !lowStockRow.exists && lowScrolled < 6 {
            app.swipeUp()
            lowScrolled += 1
        }
        XCTAssertTrue(
            lowStockRow.waitForExistence(timeout: 60),
            "the low-stock card should list the most critical SKUs"
        )
    }

    /// Trend table must have column headers, and Top Products / Low Stock must
    /// show product names resolved from the synced catalog, not raw ids.
    private func assertTrendHeadersAndProductNames(app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Month"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Revenue"].waitForExistence(timeout: 10))

        // Top products card may be below the fold — scroll to it.
        let nameRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'item '")
        ).firstMatch
        var scrolled = 0
        while !nameRow.exists && scrolled < 6 {
            app.swipeUp()
            scrolled += 1
        }
        XCTAssertTrue(
            nameRow.waitForExistence(timeout: 30),
            "top products / low stock should display product names (e.g. 'HND item 0038')"
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
