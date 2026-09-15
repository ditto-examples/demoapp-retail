import DittoSwift
import Foundation
import XCTest
@testable import ZavaRetail

/// SDK contract lock-in: on JOIN queries, `registerObserver` emissions can
/// namespace `_id` per collection alias (`{o: "order_…", c: "customer_…"}`)
/// while one-shot `execute` returns the projected `o._id` alias as a flat
/// String. (Found 2026-09-07 when the Orders screen froze after the
/// Microsoft-data cutover: the page observer's OrderSummaryRow decode kept
/// failing on `_id`; reproduced with this exact query shape and the store's
/// MAP-`_id` inventory doc present.) App rule (see OrderSummaryRow): never
/// project `o._id` in a JOIN that an observer consumes — derive identity
/// from the business key column instead.
final class JoinObserverContractTests: XCTestCase {
    func testJoinObserverNamespacesIdButExecuteFlattensIt() async throws {
        let ditto = try await Self.openIsolatedNode()
        defer { Self.removeIsolatedStore() }

        for (collection, doc) in [
            ("orders", Self.order),
            ("customers", Self.customer),
            // An inventory row with a MAP _id — present on-device in
            // production (the trigger condition this reproduces).
            ("inventory", Self.inventory)
        ] {
            try await ditto.store.execute(
                query: "INSERT INTO \(collection) DOCUMENTS (:d)",
                arguments: ["d": doc]
            ).dematerializeItems()
        }

        let query = Self.ordersPageLikeQuery

        // Path 1: one-shot execute — `o._id` lands flat as a String alias.
        let result = try await ditto.store.execute(query: query)
        defer { result.dematerializeItems() }
        let execId = result.items.first?.value["_id"] as? String
        XCTAssertNotNil(execId, "execute should return the o._id alias flat")

        // Path 2: registerObserver — `_id` arrives namespaced by alias.
        let observedId = try await firstEmission(query: query, in: ditto) as? [String: Any?]
        let namespaced = try XCTUnwrap(
            observedId,
            "observer emissions namespace _id per collection alias in JOINs"
        )
        XCTAssertEqual(namespaced["o"] as? String, "order_1")
        XCTAssertEqual(namespaced["c"] as? String, "customer_1")

        try assertSummaryRowDecodesFromNamespacedEmission()
    }

    /// Consequence the app relies on: OrderSummaryRow (o._id omitted from the
    /// projection) decodes from an observer-style emission — rows whose only
    /// `_id` key is the namespaced map PLUS projected fields.
    private func assertSummaryRowDecodesFromNamespacedEmission() throws {
        let emissionJSON: [String: Any] = [
            "_id": ["o": "order_1", "c": "customer_1"],
            "order_id": "order_1", "store_id": "store_kirkland",
            "order_date": "2026-12-13T00:00:00Z", "status": "completed",
            "subtotal": 891.05, "total": 975.7, "item_count": 5,
            "customer_id": "customer_1", "first_name": "Jennifer",
            "last_name": "Roberts"
        ]
        let row = try JSONDecoder().decode(
            OrderSummaryRow.self,
            from: JSONSerialization.data(withJSONObject: emissionJSON)
        )
        XCTAssertEqual(row.id, "order_1")
        XCTAssertEqual(row.customerName, "Jennifer Roberts")
    }

    // MARK: - Fixtures

    private static let ordersPageLikeQuery =
        "SELECT o._id, o.order_id, o.store_id, o.order_date, o.status, "
            + "o.subtotal, o.total, o.item_count, o.customer_id, c.first_name, c.last_name "
            + "FROM orders AS o INNER JOIN customers AS c ON o.customer_id = c._id "
            + "WHERE o.store_id = 'store_kirkland' AND o.deleted = false "
            + "ORDER BY o.order_date DESC, o._id DESC LIMIT 25 OFFSET 0"

    private nonisolated static var order: [String: Any] {
        [
            "_id": "order_1", "order_id": "order_1", "customer_id": "customer_1",
            "store_id": "store_kirkland", "order_date": "2026-12-13T00:00:00Z",
            "status": "completed", "subtotal": 891.05, "total": 975.7,
            "item_count": 5, "deleted": false
        ]
    }

    private nonisolated static var customer: [String: Any] {
        [
            "_id": "customer_1", "customer_id": "customer_1",
            "first_name": "Jennifer", "last_name": "Roberts"
        ]
    }

    private nonisolated static var inventory: [String: Any] {
        [
            "_id": ["store_id": "store_kirkland", "product_id": "prod_1"],
            "store_id": "store_kirkland", "product_id": "prod_1",
            "stock_level": 10, "deleted": false
        ]
    }

    private static let storeDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("join-contract-\(UUID().uuidString)", isDirectory: true)

    private static func removeIsolatedStore() {
        try? FileManager.default.removeItem(at: storeDir)
    }

    // Test-only OFFLINE node; DittoManager owns the app's online instance.
    // swiftlint:disable ditto_open_choke_point
    private static func openIsolatedNode() async throws -> Ditto {
        try await Ditto.open(config: DittoConfig(
            databaseID: "join-contract",
            connect: .smallPeersOnly(),
            persistenceDirectory: storeDir
        ))
    }

    // swiftlint:enable ditto_open_choke_point

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    private func firstEmission(query: String, in ditto: Ditto) async throws -> Any? {
        let box = Box<Any?>(nil)
        let emission = XCTestExpectation(description: "observer emission")
        let observer = try ditto.store.registerObserver(query: query) { result in
            box.value = result.items.first?.value["_id"] ?? Any?.none
            emission.fulfill()
        }
        await fulfillment(of: [emission], timeout: 20)
        observer.cancel()
        return box.value
    }
}
