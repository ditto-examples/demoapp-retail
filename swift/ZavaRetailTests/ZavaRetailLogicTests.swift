import DittoSwift
import XCTest
@testable import ZavaRetail

/// Unit tests for the app's logic layer: model decoding against REAL dataset
/// documents, formatters, config validation, the benchmark orchestration seam,
/// and the pure pieces of the screen state classes.
final class ZavaRetailLogicTests: XCTestCase {
    // MARK: - Model decoding (real documents from the benchmark dataset)

    private func sample<T: Decodable>(
        _ key: String,
        as type: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        // The fixture lives in the TEST bundle, not the app bundle.
        let url = Bundle(for: ZavaRetailLogicTests.self)
            .url(forResource: "retail_samples", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let doc = root[key],
              let docData = try? JSONSerialization.data(withJSONObject: doc) else
        {
            XCTFail("retail_samples.json missing or has no '\(key)' doc", file: file, line: line)
            throw NSError(domain: "fixtures", code: 1)
        }
        return try JSONDecoder().decode(T.self, from: docData)
    }

    func testStoreDecodes() throws {
        let store = try sample("store", as: Store.self)
        XCTAssertEqual(store.store_name, "Zava Retail Kirkland")
        XCTAssertEqual(store.location.city, "Kirkland")
        XCTAssertFalse(store.is_online)
        XCTAssertEqual(
            store.demo_default,
            true,
            "the loader flags the smallest-order store for the no-picker default"
        )
    }

    func testCategoryDecodesWithSeasonalMap() throws {
        let category = try sample("category", as: Category.self)
        XCTAssertEqual(category.category_name, "HAND TOOLS") // Microsoft ships uppercase names
        XCTAssertNotNil(category.seasonal_multipliers?["mar"])
    }

    func testProductTypeDecodes() throws {
        let type = try sample("product_type", as: ProductType.self)
        XCTAssertEqual(type.type_name, "HAMMERS")
        XCTAssertEqual(type.category_id, "cat_hand_tools")
    }

    func testProductDecodes() throws {
        let product = try sample("product", as: Product.self)
        XCTAssertEqual(product.sku, "HTHM001600")
        XCTAssertEqual(
            product.product_name,
            "Professional Claw Hammer 16oz",
            "products carry Microsoft's real catalog names"
        )
        XCTAssertEqual(product.type_id, "ptype_hammers_1")
        XCTAssertEqual(product.base_price, 41.79, accuracy: 0.001)
    }

    func testCustomerDecodes() throws {
        let customer = try sample("customer", as: Customer.self)
        XCTAssertEqual(customer.displayName, "Jasmine Johnston")
        XCTAssertEqual(customer.primary_store_id, "store_online")
    }

    func testInventoryDecodesCompositeId() throws {
        let item = try sample("inventory", as: InventoryItem.self)
        XCTAssertEqual(item._id.store_id, "store_seattle")
        XCTAssertEqual(item._id.product_id, "prod_1")
        XCTAssertEqual(item.location.aisle, "6")
        XCTAssertEqual(item.id, "store_seattle|prod_1")
    }

    func testOrderDecodesNormalized() throws {
        let order = try sample("order", as: Order.self)
        XCTAssertEqual(order.status, "completed")
        XCTAssertEqual(order.item_count, 5)
        XCTAssertEqual(order.subtotal, 1564.77, accuracy: 0.001)
        XCTAssertEqual(order.total, 1713.42, accuracy: 0.001)
        // The normalized fixture has no denormalized display fields; if one
        // ever comes back, the model must not silently depend on it.
        let raw = try XCTUnwrap(rawSample("order") as? [String: Any])
        for field in ["customer_name", "customer_email", "store_name"] {
            XCTAssertNil(raw[field], "order docs must stay normalized (no \(field))")
        }
    }

    func testOrderItemDecodesNormalized() throws {
        let item = try sample("order_item", as: OrderItem.self)
        XCTAssertEqual(item.quantity, 2)
        XCTAssertEqual(item.line_total, 775.98, accuracy: 0.001)
        XCTAssertEqual(item.store_id, "store_seattle", "store_id is denormalized from the parent order")
        let raw = try XCTUnwrap(rawSample("order_item") as? [String: Any])
        XCTAssertNotNil(raw["store_id"], "order_item docs must carry the denormalized store_id")
        for field in ["sku", "product_name"] {
            XCTAssertNil(raw[field], "order_item docs must stay normalized (no \(field))")
        }
    }

    func testJoinedRowShapesDecode() throws {
        // The orders list row (orders ⨝ customers) and line-item row
        // (order_items ⨝ products) must decode from flat DQL projections.
        let summaryJSON = """
        {"order_id":"order_197663",
         "store_id":"store_seattle","order_date":"2024-12-30T00:00:00Z",
         "status":"completed","subtotal":1564.77,"total":1713.42,"item_count":5,
         "customer_id":"customer_50000",
         "first_name":"Elizabeth","last_name":"Monroe"}
        """
        let summary = try JSONDecoder().decode(OrderSummaryRow.self, from: Data(summaryJSON.utf8))
        XCTAssertEqual(summary.customerName, "Elizabeth Monroe")
        XCTAssertEqual(summary._id, "order_197663", "_id derives from order_id (join-observer safe)")
        let lineJSON = """
        {"_id":"item_414233","order_id":"order_197663",
         "product_id":"prod_64","quantity":2,"unit_price":387.99,
         "discount_percent":0,"line_total":775.98,
         "product_name":"Track Saw Kit 55-inch Rail","sku":"PTTS055000"}
        """
        let line = try JSONDecoder().decode(OrderLineRow.self, from: Data(lineJSON.utf8))
        XCTAssertEqual(line.product_name, "Track Saw Kit 55-inch Rail")
    }

    /// Raw fixture access for the normalized-shape assertions above.
    private func rawSample(_ key: String) throws -> Any {
        let url = Bundle(for: ZavaRetailLogicTests.self)
            .url(forResource: "retail_samples", withExtension: "json")
        let data = try Data(contentsOf: XCTUnwrap(url))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root[key])
    }

    // MARK: - System collection row parsing

    func testSyncStatusInfoParses() {
        let row: [String: Any?] = [
            "_id": "SELECT * FROM orders WHERE store_id = 'store_seattle'",
            "is_ditto_server": true,
            "documents": ["sync_session_status": "Connected", "synced_up_to_local_commit_id": NSNumber(value: 42)]
        ]
        let info = SyncStatusInfo(from: row)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.syncSessionStatus, "Connected")
        XCTAssertEqual(info?.syncedUpToLocalCommitId, 42)
        XCTAssertTrue(info?.isDittoServer ?? false)
        XCTAssertNil(SyncStatusInfo(from: ["no_id": 1]))
    }

    func testIndexInfoParses() {
        let info = IndexInfo(from: ["_id": "orders:zava_orders_store", "fields": [["store_id": 1]]])
        XCTAssertEqual(info?.collection, "orders")
        XCTAssertEqual(info?.id, "orders:zava_orders_store")
        XCTAssertNil(IndexInfo(from: ["fields": []]))
    }

    // MARK: - Formatters

    func testFormatters() {
        XCTAssertEqual(Formatters.usd(250.88), "$250.88")
        XCTAssertEqual(Formatters.dateTime("2025-06-27T18:20:00Z"), "2025-06-27 18:20")
        XCTAssertEqual(Formatters.dateTime("short"), "short")
    }

    // MARK: - DatabaseConfig validation (pure decision code, no live Ditto)

    func testMakeDittoConfigRejectsBadURLs() {
        let config = DatabaseConfig(databaseID: "db", developmentToken: "t", serverURL: "not a url")
        XCTAssertThrowsError(try config.makeDittoConfig(persistenceDirectory: URL(fileURLWithPath: "/tmp")))
        let bare = DatabaseConfig(databaseID: "db", developmentToken: "t", serverURL: "1e8347b2-uuid-without-scheme")
        XCTAssertThrowsError(try bare.makeDittoConfig(persistenceDirectory: URL(fileURLWithPath: "/tmp")))
    }

    func testMakeDittoConfigAcceptsHTTPS() throws {
        let config = DatabaseConfig(
            databaseID: "db",
            developmentToken: "t",
            serverURL: "https://example.cloud.dittolive.app"
        )
        _ = try config.makeDittoConfig(persistenceDirectory: URL(fileURLWithPath: "/tmp/zava-test"))
    }

    func testPersistenceDirectoryIsCreated() throws {
        let url = try DittoManager.persistenceDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.path.hasSuffix("zava/ditto"))
    }

    func testBenchmarkEntryDecodesJoinsCatalogFields() throws {
        // retail-joins entries carry expected_count / sql_equivalent extras;
        // the decoder must tolerate and expose the expected count.
        let json = """
        {"query":"SELECT 1","category":"JOIN_INNER","sql_equivalent":"SELECT 1",
         "expected_count":42,"expected_first_rows_hash":"sha256:abc"}
        """
        let entry = try JSONDecoder().decode(BenchmarkEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.expected_count, 42)
        XCTAssertFalse(entry.isMutating)
        let upsert = BenchmarkEntry(
            query: "INSERT INTO orders DOCUMENTS(deserialize_json('{\"_id\":\"bench-order-ups\"}')) ON ID CONFLICT DO UPDATE",
            category: "UPSERT", preQueries: nil, postQueries: nil, expected_count: 1
        )
        XCTAssertTrue(upsert.isMutating, "UPSERT writes bench docs — it needs the confirm gate + id suffixing")
    }

    // MARK: - Benchmark orchestration seam (order, counting, cleanup-on-failure)

    private actor CallRecorder {
        var calls: [String] = []
        var count = 0
        func record(_ call: String) {
            calls.append(call)
            count += 1
        }
    }

    func testBenchmarkOrchestrationOrder() async throws {
        let recorder = CallRecorder()
        let prepared = PreparedBenchmark(
            name: "t", category: "INDEX_SELECT", isMutating: false,
            preQueries: ["CREATE INDEX a"], query: "SELECT 1",
            postQueries: ["DROP INDEX a"], substitutions: []
        )
        let result = try await DittoManager.runBenchmarkOrchestrated(prepared, iterations: 3) { query in
            await recorder.record(query)
            return query == "SELECT 1" ? 7 : 0
        }
        let calls = await recorder.calls
        XCTAssertEqual(calls, ["CREATE INDEX a", "SELECT 1", "SELECT 1", "SELECT 1", "DROP INDEX a"])
        XCTAssertEqual(result.iterations, 3)
        XCTAssertEqual(result.resultCount, 7)
    }

    func testBenchmarkOrchestrationRunsCleanupOnFailure() async {
        let recorder = CallRecorder()
        struct Boom: Error {}
        let prepared = PreparedBenchmark(
            name: "t", category: "INSERT", isMutating: true,
            preQueries: ["INSERT seed"], query: "INSERT timed",
            postQueries: ["DELETE cleanup"], substitutions: []
        )
        do {
            _ = try await DittoManager.runBenchmarkOrchestrated(prepared, iterations: 5) { query in
                await recorder.record(query)
                let count = await recorder.count
                if query == "INSERT timed", count > 2 {
                    throw Boom()
                }
                return 1
            }
            XCTFail("the failing iteration must rethrow after cleanup")
        } catch {
            // expected
        }
        let calls = await recorder.calls
        XCTAssertEqual(
            calls,
            ["INSERT seed", "INSERT timed", "INSERT timed", "DELETE cleanup"],
            "cleanup must run even when a timed iteration fails"
        )
    }

    /// Navigating away mid-run cancels the calling task — cleanup must STILL
    /// run (the synthetic doc must not stay on Big Peer). The sleep-before-
    /// record ordering makes this test fail against the pre-fix runner (the
    /// cancelled task throws before the cleanup call is ever recorded).
    func testBenchmarkOrchestrationRunsCleanupOnCancellation() async {
        let recorder = CallRecorder()
        let prepared = PreparedBenchmark(
            name: "t", category: "INSERT", isMutating: true,
            preQueries: [], query: "INSERT timed",
            postQueries: ["DELETE cleanup"], substitutions: []
        )
        let task = Task {
            try await DittoManager.runBenchmarkOrchestrated(prepared, iterations: 50) { query in
                try await Task.sleep(for: .milliseconds(10)) // throws if the calling task is cancelled
                await recorder.record(query)
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(55)) // a few iterations in
        task.cancel()
        _ = try? await task.value
        let calls = await recorder.calls
        XCTAssertTrue(
            calls.contains("DELETE cleanup"),
            "cleanup must run even when the run is cancelled mid-flight"
        )
    }

    // MARK: - Store-id invariant (m7: data-derived string flows into DQL)

    func testIsValidStoreId() {
        XCTAssertTrue(DittoManager.isValidStoreId("store_seattle"))
        XCTAssertTrue(DittoManager.isValidStoreId("store-online_2"))
        XCTAssertFalse(DittoManager.isValidStoreId("store'; DROP TABLE stores; --"))
        XCTAssertFalse(DittoManager.isValidStoreId(""))
    }

    func testInvalidStoreIdSkipsSubstitution() {
        let e = BenchmarkEntry(
            query: "SELECT * FROM orders WHERE store_id = 'store_seattle'",
            category: "SELECT", preQueries: nil, postQueries: nil, expected_count: nil
        )
        let prepared = QueryPreparation.prepare(name: "t", entry: e, storeId: "store'; --", runId: "r1")
        XCTAssertTrue(
            prepared.query.contains("store_seattle"),
            "an unsafe store id must not be interpolated into DQL"
        )
        XCTAssertTrue(prepared.substitutions.contains { $0.contains("doesn't match") })
    }

    // MARK: - EVICT cleanup extraction (m3)

    func testEvictCleanupScalarId() {
        let e = BenchmarkEntry(
            query: "EVICT FROM customers WHERE _id = 'bench-cust-evict-uuid'",
            category: "EVICT", preQueries: nil, postQueries: nil, expected_count: nil
        )
        let cleanup = QueryPreparation.evictCleanup(entry: e) { $0.replacingOccurrences(of: "bench-", with: "bench-r1-") }
        XCTAssertEqual(cleanup, "DELETE FROM customers WHERE _id = 'bench-r1-cust-evict-uuid'")
    }

    func testEvictCleanupCompositeId() {
        let e = BenchmarkEntry(
            query: "EVICT FROM inventory WHERE _id = {'store_id': 'store_seattle', 'product_id': 'bench-prod'}",
            category: "EVICT", preQueries: nil, postQueries: nil, expected_count: nil
        )
        let cleanup = QueryPreparation.evictCleanup(entry: e) { $0.replacingOccurrences(of: "bench-", with: "bench-r2-") }
        XCTAssertEqual(
            cleanup,
            "DELETE FROM inventory WHERE _id = {'store_id': 'store_seattle', 'product_id': 'bench-r2-prod'}"
        )
    }

    func testEvictCleanupBulkOrderId() {
        // The joins catalog's bulk EVICT predicates on order_id, not _id
        // (order_items__evict__bulk_by_order) — cleanup must still derive.
        let e = BenchmarkEntry(
            query: "EVICT FROM order_items WHERE order_id = 'bench-bulk-evict'",
            category: "EVICT", preQueries: nil, postQueries: nil, expected_count: nil
        )
        let cleanup = QueryPreparation.evictCleanup(entry: e) { $0.replacingOccurrences(of: "bench-", with: "bench-r9-") }
        XCTAssertEqual(cleanup, "DELETE FROM order_items WHERE order_id = 'bench-r9-bulk-evict'")
    }

    func testEvictCleanupIgnoresNonEvict() {
        let e = BenchmarkEntry(query: "SELECT 1", category: "SELECT", preQueries: nil, postQueries: nil, expected_count: nil)
        XCTAssertNil(QueryPreparation.evictCleanup(entry: e) { $0 })
    }

    // MARK: - Paging (LIMIT/OFFSET math)

    func testPagingQueryBuildsLimitOffset() {
        let query = Paging.pageQuery(
            base: "SELECT * FROM orders WHERE deleted = false",
            orderBy: "order_date DESC, _id DESC",
            page: 3,
            pageSize: 25
        )
        XCTAssertEqual(
            query,
            "SELECT * FROM orders WHERE deleted = false ORDER BY order_date DESC, _id DESC LIMIT 25 OFFSET 50"
        )
    }

    func testPagingCountsAndClamps() {
        XCTAssertEqual(Paging.pageCount(total: 0, pageSize: 25), 1)
        XCTAssertEqual(Paging.pageCount(total: 25, pageSize: 25), 1)
        XCTAssertEqual(Paging.pageCount(total: 26, pageSize: 25), 2)
        XCTAssertEqual(Paging.pageCount(total: 24921, pageSize: 25), 997)
        XCTAssertEqual(Paging.clampPage(5000, total: 100, pageSize: 25), 4)
        XCTAssertEqual(Paging.clampPage(-3, total: 100, pageSize: 25), 1)
    }

    func testOrdersSearchQueryUsesLikeOnOrderNumberAndCustomer() {
        // Partial order number OR customer name — both via case-insensitive
        // ILIKE with a contains-pattern arg. The customer name lives on the
        // joined customers collection in the normalized schema.
        let q = OrdersState.searchQuery
        XCTAssertTrue(q.contains("INNER JOIN customers AS c ON o.customer_id = c._id"))
        XCTAssertTrue(q.contains("o.order_id ILIKE :like"))
        XCTAssertTrue(q.contains("c.first_name ILIKE :like"))
        XCTAssertTrue(q.contains("c.last_name ILIKE :like"))
        XCTAssertTrue(q.contains("o.store_id = :storeId"))
        XCTAssertTrue(q.contains("ORDER BY o.order_date DESC, o._id DESC"))
        XCTAssertTrue(q.contains("LIMIT 50"))
        XCTAssertFalse(q.contains("customer_name"), "no denormalized fields in the join shape")
    }

    func testOrdersSearchTermSanitization() {
        // Whitespace is trimmed; leading '#' is stripped because the list
        // renders "order_197663" as "#197663".
        XCTAssertEqual(OrdersState.sanitizedSearchTerm("  20250115  "), "20250115")
        XCTAssertEqual(OrdersState.sanitizedSearchTerm("#197663"), "197663")
        XCTAssertEqual(OrdersState.sanitizedSearchTerm("##"), "")
        XCTAssertEqual(OrdersState.sanitizedSearchTerm("   "), "")
        // '%'/'_' pass through as ILIKE wildcards (documented in the sheet).
        XCTAssertEqual(OrdersState.sanitizedSearchTerm("2025%"), "2025%")
    }

    // MARK: - Screen state pure logic

    func testOrdersCutoffAnchorsToDataNotClock() {
        XCTAssertEqual(
            OrdersState.cutoffDate(from: "2025-06-27T18:20:00Z", days: 30),
            "2025-05-28T18:20:00Z"
        )
        XCTAssertNil(OrdersState.cutoffDate(from: "not a date", days: 30))
    }

    @MainActor
    func testProductsVisibleRowsPrefersSearchResults() {
        let state = ProductsState()
        let paged = Product(
            _id: "p1", product_id: "p1", sku: "A-1", product_name: "Hammer",
            category_id: "cat", type_id: nil, cost: 1, base_price: 2, gross_margin_percent: 50,
            deleted: false
        )
        let found = Product(
            _id: "p2", product_id: "p2", sku: "A-2", product_name: "Nail",
            category_id: "cat", type_id: nil, cost: 1, base_price: 2, gross_margin_percent: 50,
            deleted: false
        )
        state.rows = [.init(product: paged, stock: nil)]
        XCTAssertEqual(state.visibleRows.map(\.product.sku), ["A-1"])
        state.searchResults = [found]
        XCTAssertTrue(state.isSearching)
        XCTAssertEqual(state.visibleRows.map(\.product.sku), ["A-2"])
        state.searchResults = nil
        XCTAssertEqual(state.visibleRows.map(\.product.sku), ["A-1"])
    }

    func testCustomersStoreFilterQueryChoice() {
        XCTAssertEqual(
            CustomersState.whereClause(thisStoreOnly: true, storeId: "store_a"),
            CustomersState.storeWhere,
            "filtered mode must use the query-side primary_store_id filter"
        )
        XCTAssertEqual(
            CustomersState.whereClause(thisStoreOnly: false, storeId: "store_a"),
            CustomersState.directoryWhere
        )
        // No store selected yet: never emit a dangling :storeId filter
        XCTAssertEqual(
            CustomersState.whereClause(thisStoreOnly: true, storeId: nil),
            CustomersState.directoryWhere
        )
    }
}
