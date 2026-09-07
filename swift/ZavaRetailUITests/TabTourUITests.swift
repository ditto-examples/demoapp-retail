import XCTest

/// Tab tour: visits every screen against the synced Microsoft dataset — Orders
/// list + detail (INNER JOINs), Products + detail (composite-id stock),
/// Customers (50K directory + exact-email lookup), Ditto system views. Exists
/// to prove the screens work on live data; as a side effect it exercises most
/// view code for coverage. Runs against store_kirkland: the loader's flagged
/// default (fewest orders, 2,975) — the fastest live store to exercise.
final class TabTourUITests: XCTestCase {
    @MainActor
    func testTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-selectedStoreId", "store_kirkland"]
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

        assertOrdersListSearchAndDetail(app: app)

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
        //     chosen anchor customer (proves 50K-directory sync) ---
        app.tabBars.buttons["Customers"].tap()
        let search = app.searchFields["Search name, or exact email…"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("jasmine.johnston.40000@example.com")
        let jasmine = app.staticTexts["Jasmine Johnston"]
        XCTAssertTrue(
            jasmine.waitForExistence(timeout: 60),
            "exact-email lookup should find the anchor customer"
        )

        // Dismiss the software keyboard — it covers the tab bar otherwise.
        // The .searchable field's keyboard has a "Search" key, not "return".
        if app.keyboards.element.exists {
            let searchKey = app.keyboards.buttons["Search"]
            let returnKey = app.keyboards.buttons["return"]
            (searchKey.exists ? searchKey : returnKey).tap()
        }

        tourDittoTab(app: app)
    }

    /// Orders search: the standard .searchable field narrows the paged list via
    /// ILIKE on a partial order number, and its standard × button clears back
    /// to the paged list (regression: the field must be the platform control,
    /// not a bare TextField with no clear affordance).
    private func assertOrdersSearch(app: XCUIApplication) {
        let search = app.searchFields["Search order # or customer…"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("140617")
        // The tour's order anchor is order_140617 — a real Microsoft row at the
        // tour's store (Kirkland): Joseph Mahoney, 5 line items, $314.36
        // subtotal; "140617" is a unique substring among order ids ≤ 197665.
        let hit = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '140617'")
        ).firstMatch
        XCTAssertTrue(
            hit.waitForExistence(timeout: 120),
            "searching '140617' should find order_140617"
        )
        // The standard clear affordance must exist — tapping it empties the
        // field, which restores the paged observer list.
        let clear = search.buttons["Clear text"]
        XCTAssertTrue(
            clear.waitForExistence(timeout: 10),
            "the standard search field must show its × clear button"
        )
        clear.tap()
    }

    /// Orders tab: the paged list fills from sync, ILIKE search narrows it by
    /// partial order number, and a cell opens the JOIN-backed detail view.
    private func assertOrdersListSearchAndDetail(app: XCUIApplication) {
        // --- Orders: LIKE search narrows the list by partial order number ---
        app.tabBars.buttons["Orders"].tap()
        let ordersTable = app.collectionViews.firstMatch
        // Kirkland pulls 2,975 orders under a chain-wide 414K-item ledger:
        // first sync to the full Microsoft dataset takes minutes on a cold
        // app container; the table waits generously (warm boots pass fast).
        XCTAssertTrue(ordersTable.waitForExistence(timeout: 600))
        let firstOrderCell = ordersTable.cells.firstMatch
        XCTAssertTrue(
            firstOrderCell.waitForExistence(timeout: 300),
            "orders should sync for the selected store"
        )
        // Search AFTER rows exist locally: on a cold store the anchor order
        // may not have synced while the table first materializes.
        assertOrdersSearch(app: app)
        // The search is cleared inside assertOrdersSearch — the paged list
        // is back; the first cell is tappable again.
        let firstCellAfterSearch = ordersTable.cells.firstMatch
        XCTAssertTrue(
            firstCellAfterSearch.waitForExistence(timeout: 60),
            "the paged list should be back after clearing search"
        )
        firstCellAfterSearch.tap()
        XCTAssertTrue(app.staticTexts["Line items"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap() // back
    }

    /// Dashboard low-stock card: badge and the designed empty state must
    /// render. Microsoft's real shelf counts are healthy (min 28 units
    /// chain-wide), so "critical SKUs" is honestly the empty state here — the
    /// assertion proves the card renders its data-driven state, not a blank.
    private func assertLowStockCard(app: XCUIApplication) {
        let lowStockBadge = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'under 5 units' OR label == 'No low stock found'")
        ).firstMatch
        XCTAssertTrue(
            lowStockBadge.waitForExistence(timeout: 120),
            "the low-stock card should render a badge (count or empty state)"
        )
        let stateText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'left' OR label == 'out' OR "
                + "label CONTAINS 'Everything at this store'")
        ).firstMatch
        var lowScrolled = 0
        while !stateText.exists && lowScrolled < 6 {
            app.swipeUp()
            lowScrolled += 1
        }
        XCTAssertTrue(
            stateText.waitForExistence(timeout: 60),
            "the low-stock card should render rows or its 0-row message"
        )
    }

    /// Trend table must have column headers, and Top Products / Low Stock must
    /// show the Microsoft-catalog product names, not raw ids (the catalog's
    /// client-side product_id → name resolution, and the dataset's realistic
    /// names, are both under test here).
    private func assertTrendHeadersAndProductNames(app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Month"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Revenue"].waitForExistence(timeout: 10))

        // Raw ids regressing into the UI look like "prod_ele_0022"; names like
        // "Cordless Drill 18V Li-Ion" must render instead. Scroll first so the
        // card rows materialize, then assert no raw-id label is on screen.
        var scrolled = 0
        while scrolled < 6 {
            app.swipeUp()
            scrolled += 1
        }
        let rawIds = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'prod_'")
        )
        XCTAssertEqual(
            rawIds.count, 0,
            "product rows must show resolved names (e.g. 'Random Orbit Sander 5-inch'), not raw ids"
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
