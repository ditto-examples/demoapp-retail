import UIKit
import XCTest
@testable import ZavaRetail

/// Smoke-level unit tests for the SwiftUI reference app (PLAN §6 plumbing
/// checklist): the pure, decision-bearing code — benchmark catalog decoding,
/// store/bench-id substitution, timing stats, and font registration.
final class ZavaRetailTests: XCTestCase {
    // MARK: - Benchmark catalog

    func testBenchmarkCatalogLoadsAndGroups() throws {
        let catalog = try BenchmarkCatalog.load()
        XCTAssertEqual(catalog.entries.count, 96, "the bundled catalog ships all 96 benchmarks")
        let collections = catalog.groups.map(\.collection)
        XCTAssertTrue(collections.contains("orders"))
        XCTAssertTrue(collections.contains("order_items"))
        XCTAssertTrue(
            collections.contains("joins"),
            "the retail-joins catalog's JOIN groups must ship in the bundle"
        )
    }

    // MARK: - QueryPreparation

    private func entry(
        _ query: String,
        category: String = "SELECT",
        pre: [String]? = nil,
        post: [String]? = nil
    ) -> BenchmarkEntry {
        BenchmarkEntry(
            query: query,
            category: category,
            preQueries: pre,
            postQueries: post,
            expected_count: nil
        )
    }

    func testStoreSubstitution() {
        let e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false")
        let prepared = QueryPreparation.prepare(name: "t", entry: e, storeId: "store_tacoma", runId: "testrun1")
        XCTAssertTrue(prepared.query.contains("store_id = 'store_tacoma'"))
        XCTAssertFalse(prepared.query.contains("store_seattle"))
        XCTAssertFalse(prepared.substitutions.isEmpty, "substitution must be visible in the UI")
    }

    func testNoSubstitutionWhenSeattleSelected() {
        let e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle'")
        let prepared = QueryPreparation.prepare(name: "t", entry: e, storeId: "store_seattle", runId: "testrun1")
        XCTAssertTrue(prepared.query.contains("store_seattle"))
        XCTAssertTrue(prepared.substitutions.isEmpty)
    }

    func testMutatingRunGetsFreshIdsAndDeleteCleanup() {
        let e = entry(
            "INSERT INTO customers DOCUMENTS(deserialize_json('{\"_id\":\"bench-cust-insert-uuid\"}')) ON ID CONFLICT DO UPDATE",
            category: "INSERT",
            post: ["EVICT FROM customers WHERE _id = 'bench-cust-insert-uuid'"]
        )
        let prepared = QueryPreparation.prepare(name: "t", entry: e, storeId: "store_seattle", runId: "run42")
        XCTAssertTrue(prepared.isMutating)
        XCTAssertTrue(
            prepared.query.contains("bench-run42-cust-insert-uuid"),
            "bench ids get the per-run suffix: \(prepared.query)"
        )
        // EVICT cleanup rewritten to propagating DELETE, id rewritten too
        XCTAssertEqual(
            prepared.postQueries,
            ["DELETE FROM customers WHERE _id = 'bench-run42-cust-insert-uuid'"]
        )
    }

    func testEvictBenchmarkGetsPropagatingCleanupAppended() {
        let e = entry(
            "EVICT FROM customers WHERE _id = 'bench-cust-evict-uuid'",
            category: "EVICT",
            pre: ["INSERT INTO customers DOCUMENTS(deserialize_json('{\"_id\":\"bench-cust-evict-uuid\"}'))"]
        )
        let prepared = QueryPreparation.prepare(name: "t", entry: e, storeId: "store_seattle", runId: "run7")
        XCTAssertEqual(
            prepared.postQueries,
            ["DELETE FROM customers WHERE _id = 'bench-run7-cust-evict-uuid'"]
        )
        // preQueries get the same transform (dropping that map must fail loudly).
        XCTAssertEqual(
            prepared.preQueries,
            ["INSERT INTO customers DOCUMENTS(deserialize_json('{\"_id\":\"bench-run7-cust-evict-uuid\"}'))"]
        )
    }

    func testReadOnlyBenchmarksAreUntouched() {
        let e = entry("SELECT * FROM customers WHERE deleted = false", category: "SELECT")
        let prepared = QueryPreparation.prepare(name: "t", entry: e, storeId: "store_seattle")
        XCTAssertEqual(prepared.query, e.query)
        XCTAssertTrue(prepared.preQueries.isEmpty)
        XCTAssertTrue(prepared.postQueries.isEmpty)
        XCTAssertTrue(prepared.substitutions.isEmpty)
    }

    // MARK: - BenchmarkStats (matches the harness's population method)

    func testBenchmarkStats() {
        let stats = BenchmarkStats(durationsMs: [1, 2, 3, 4, 5])
        XCTAssertEqual(stats.meanMs, 3.0, accuracy: 0.0001)
        XCTAssertEqual(stats.medianMs, 3.0, accuracy: 0.0001)
        XCTAssertEqual(stats.minMs, 1.0)
        XCTAssertEqual(stats.maxMs, 5.0)
        // p95 = sorted[floor(n * 0.95)] = sorted[4]
        XCTAssertEqual(stats.p95Ms, 5.0)
    }

    func testBenchmarkStatsEmpty() {
        let stats = BenchmarkStats(durationsMs: [])
        XCTAssertEqual(stats.meanMs, 0)
    }

    // MARK: - Fonts (vendored Anvil fonts must resolve — M1 checkpoint)

    func testAnvilFontsRegistered() {
        // Hosted unit test: Bundle.main is the app bundle.
        for resource in ["inter_regular", "ibm_plex_mono_regular", "ibm_plex_mono_bold", "ibm_plex_mono_italic"] {
            XCTAssertNotNil(
                Bundle.main.url(forResource: resource, withExtension: "ttf"),
                "\(resource).ttf must be a bundled resource"
            )
        }
        FontRegistration.registerAnvilFonts()
        XCTAssertNotNil(UIFont(name: "Inter", size: 12), "Inter (PostScript name) must resolve")
        XCTAssertNotNil(UIFont(name: "IBMPlexMono", size: 12), "IBM Plex Mono must resolve")
        XCTAssertNotNil(UIFont(name: "IBMPlexMono-Bold", size: 12))
        XCTAssertNotNil(UIFont(name: "IBMPlexMono-Italic", size: 12))
    }
}
