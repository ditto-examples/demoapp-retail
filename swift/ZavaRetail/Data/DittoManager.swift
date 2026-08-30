import Foundation
import DittoSwift
import OSLog

/// The single owner of the app's Ditto instance (edge-studio pattern,
/// PLAN §1.3): an actor singleton. All Ditto access flows through here.
///
/// Swift 6 concurrency design:
/// - The actor owns mutable state (instance, subscriptions, selection).
/// - Callbacks handed to the SDK are `@Sendable` — they capture *values*
///   (Sendable models / strings), never `self` or other non-Sendable state.
/// - Observer delivery happens on a serial utility queue; decoded Sendable
///   models hop to the main actor for UI state.
actor DittoManager {
    static let shared = DittoManager()
    static let log = Logger(subsystem: "live.ditto.zava", category: "ditto")
    private init() {}

    private(set) var ditto: Ditto?
    private var sharedSubscriptions: [DittoSyncSubscription] = []
    private var storeSubscriptions: [DittoSyncSubscription] = []
    private var selectedStoreId: String?

    /// Serial queue for observer delivery — heavy JSON decode work must not
    /// run on the main thread (the SDK's default `deliverOn`).
    private static let observerDeliveryQueue = DispatchQueue(
        label: "live.ditto.zava.observerDelivery",
        qos: .utility
    )

    // MARK: - Open / close

    /// Opens the Ditto instance, authenticates with the development token,
    /// registers the shared-catalog subscriptions and supporting indexes, and
    /// starts sync. Idempotent: repeated calls return the live instance.
    ///
    /// - Parameter onError: async-auth and other post-open errors are reported
    ///   here (never thrown from SDK callbacks) — a `@MainActor @Sendable`
    ///   sink the AppState installs.
    @discardableResult
    func open(
        config: DatabaseConfig,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Ditto {
        if let ditto { return ditto }

        let persistenceDirectory = try Self.persistenceDirectory()
        let dittoConfig = try config.makeDittoConfig(persistenceDirectory: persistenceDirectory)
        let instance = try await Ditto.open(config: dittoConfig)

        // Capture only the values needed by the closure to avoid retaining
        // the DittoManager actor through the SDK-held expirationHandler.
        let token = config.developmentToken
        instance.auth?.expirationHandler = { dittoAuth, _ in
            dittoAuth.auth?.login(token: token, provider: .development) { _, error in
                if let error {
                    Task { @MainActor in
                        onError("Ditto auth failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        ditto = instance
        try registerSharedSubscriptions(on: instance)
        try await createSupportingIndexes(on: instance)
        try await Self.startSyncNow(instance)
        return instance
    }

    /// App-global persistence directory (Documents/zava/ditto).
    nonisolated static func persistenceDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("zava/ditto", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Subscriptions (PLAN §4.1 — the four subscription__* queries verbatim)

    private func registerSharedSubscriptions(on ditto: Ditto) throws {
        guard sharedSubscriptions.isEmpty else { return }
        sharedSubscriptions = [
            try ditto.sync.registerSubscription(query: "SELECT * FROM stores"),
            try ditto.sync.registerSubscription(query: "SELECT * FROM categories"),
            try ditto.sync.registerSubscription(query: "SELECT * FROM products"),
            // subscription__customers_all: the full customer directory — a
            // walk-in could be anyone, so devices hold all of them.
            try ditto.sync.registerSubscription(
                query: "SELECT * FROM customers WHERE deleted = false"
            ),
        ]
    }

    /// The benchmark README is explicit: composite-_id subfield queries need
    /// an explicit index (the auto-_id index does not help). App-namespaced
    /// (`zava_*`) so the Query Runner's benchmark postQueries (DROP INDEX on
    /// benchmark names) can never drop the app's own indexes.
    private func createSupportingIndexes(on ditto: Ditto) async throws {
        try await ditto.store.execute(
            query: "CREATE INDEX IF NOT EXISTS zava_inventory_store ON inventory (_id.store_id)"
        ).dematerializeItems()
        try await ditto.store.execute(
            query: "CREATE INDEX IF NOT EXISTS zava_orders_store ON orders (store_id, deleted)"
        ).dematerializeItems()
        try await ditto.store.execute(
            query: "CREATE INDEX IF NOT EXISTS zava_order_items_store ON order_items (store_id, deleted)"
        ).dematerializeItems()
    }

    // MARK: - Store selection (the store-switch showcase, PLAN §4.1)

    /// Re-points the device at a store: cancels the per-store subscriptions,
    /// EVICTs the previous store's data (local-only removal — the EVICT vs
    /// DELETE distinction is a teaching moment), and registers subscriptions
    /// for the new store.
    func applyStoreSelection(_ storeId: String) async throws {
        guard let ditto, storeId != selectedStoreId else { return }
        Self.log.info("store selection → \(storeId, privacy: .public): re-registering per-store subscriptions")

        for subscription in storeSubscriptions { subscription.cancel() }
        storeSubscriptions = []

        // Evict data from any previous store. All three per-store collections
        // carry a top-level store_id (inventory has both that and the
        // composite _id), so one simple predicate works everywhere.
        for collection in ["order_items", "orders", "inventory"] {
            try await ditto.store.execute(
                query: "EVICT FROM \(collection) WHERE store_id != :storeId",
                arguments: ["storeId": storeId]
            ).dematerializeItems()
        }

        storeSubscriptions = [
            try ditto.sync.registerSubscription(
                query: "SELECT * FROM inventory WHERE _id.store_id = :storeId AND deleted = false",
                arguments: ["storeId": storeId]
            ),
            try ditto.sync.registerSubscription(
                query: "SELECT * FROM orders WHERE store_id = :storeId AND deleted = false",
                arguments: ["storeId": storeId]
            ),
            try ditto.sync.registerSubscription(
                query: "SELECT * FROM order_items WHERE store_id = :storeId AND deleted = false",
                arguments: ["storeId": storeId]
            ),
        ]
        selectedStoreId = storeId
    }

    // MARK: - Sync funnels (edge-studio pattern)

    /// The ONLY paths to sync.start()/stop() — concentrated so the call site
    /// is greppable and the SDK call runs off the caller's executor (the
    /// detached utility task avoids a priority inversion when called from the
    /// main actor).
    nonisolated static func startSyncNow(_ ditto: Ditto) async throws {
        try await Task.detached(priority: .utility) {
            try ditto.sync.start()
        }.value
    }

    nonisolated static func stopSyncNow(_ ditto: Ditto) async {
        await Task.detached(priority: .utility) {
            ditto.sync.stop()
        }.value
    }

    // MARK: - Queries

    /// One-shot DQL execution with result decoding inside the actor — decoded
    /// Sendable models cross to the UI; result cursors are dematerialized here.
    func fetch<T: Decodable & Sendable>(
        _ query: String,
        arguments: [String: Sendable]? = nil,
        as type: T.Type
    ) async throws -> [T] {
        let ditto = try requireInstance()
        let result = try await ditto.store.execute(
            query: query,
            arguments: arguments?.mapValues { $0 as Any? } ?? [:]
        )
        return try Self.decodeItems(result, as: type)
    }

    /// Raw-items variant for the Query Runner, as pretty-printed JSON strings
    /// (Sendable — `[String: Any?]` dictionaries must not cross actors).
    func fetchRawItemsJSON(
        _ query: String,
        arguments: [String: Sendable]? = nil
    ) async throws -> [String] {
        let ditto = try requireInstance()
        let result = try await ditto.store.execute(
            query: query,
            arguments: arguments?.mapValues { $0 as Any? } ?? [:]
        )
        defer { result.dematerializeItems() }
        return try result.items.map { item in
            let cleaned = item.value.compactMapValues { $0 }
            let data = try JSONSerialization.data(
                withJSONObject: cleaned,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Executes a statement whose results we don't render (DDL, EVICT, …).
    func execute(_ query: String, arguments: [String: Sendable]? = nil) async throws {
        let ditto = try requireInstance()
        try await ditto.store.execute(
            query: query,
            arguments: arguments?.mapValues { $0 as Any? } ?? [:]
        ).dematerializeItems()
    }

    /// Executes and returns the row count without decoding rows — the timed
    /// unit for the Query Runner.
    func executeReturningRowCount(
        _ query: String,
        arguments: [String: Sendable]? = nil
    ) async throws -> Int {
        let ditto = try requireInstance()
        let result = try await ditto.store.execute(
            query: query,
            arguments: arguments?.mapValues { $0 as Any? } ?? [:]
        )
        defer { result.dematerializeItems() }
        return result.items.count
    }

    // MARK: - Query Runner (PLAN §4.2.6)

    /// Runs a prepared benchmark: preQueries once (index create / seed doc),
    /// N timed iterations of the query, postQueries once (index drop /
    /// cleanup). Timing includes execution only, never rendering — the same
    /// unit the benchmark harness measures.
    func runBenchmark(
        _ prepared: PreparedBenchmark,
        iterations: Int
    ) async throws -> BenchmarkRunResult {
        for query in prepared.preQueries {
            try await execute(query)
        }
        var durationsMs: [Double] = []
        durationsMs.reserveCapacity(iterations)
        var rowCount = 0
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            rowCount = try await executeReturningRowCount(prepared.query)
            let elapsed = start.duration(to: ContinuousClock.now)
            let seconds = Double(elapsed.components.seconds)
            let attos = Double(elapsed.components.attoseconds)
            durationsMs.append(seconds * 1_000 + attos / 1e15)
        }
        // Cleanup always runs, even if a timed iteration failed midway.
        for query in prepared.postQueries {
            try await execute(query)
        }
        return BenchmarkRunResult(
            iterations: iterations,
            stats: BenchmarkStats(durationsMs: durationsMs),
            resultCount: rowCount
        )
    }

    // MARK: - Observers

    /// Registers a store observer: results are decoded on the serial delivery
    /// queue (cursors dematerialized immediately), then decoded Sendable
    /// models hop to the main actor.
    func observe<T: Decodable & Sendable>(
        _ query: String,
        arguments: [String: Sendable]? = nil,
        as type: T.Type,
        onChange: @escaping @MainActor @Sendable ([T]) -> Void
    ) async throws -> DittoStoreObserver {
        let ditto = try requireInstance()
        let args = arguments?.mapValues { $0 as Any? }
        return try ditto.store.registerObserver(
            query: query,
            arguments: args,
            deliverOn: Self.observerDeliveryQueue
        ) { result in
            // This closure is @Sendable and runs on the delivery queue.
            // It captures NO non-Sendable state.
            let decoded: [T]
            do {
                decoded = try Self.decodeItems(result, as: type)
            } catch {
                decoded = []
                assertionFailure("observer decode failed: \(error)")
            }
            Task { @MainActor in
                onChange(decoded)
            }
        }
    }

    /// JSON-row variant for the system:* collections (no Codable model).
    /// Delivers one compact-JSON string per row (Sendable); observers parse
    /// on the main actor.
    func observeRawJSON(
        _ query: String,
        onChange: @escaping @MainActor @Sendable ([String]) -> Void
    ) async throws -> DittoStoreObserver {
        let ditto = try requireInstance()
        return try ditto.store.registerObserver(
            query: query,
            deliverOn: Self.observerDeliveryQueue
        ) { result in
            // This closure is @Sendable and runs on the delivery queue.
            let rows: [String] = result.items.compactMap { item in
                let cleaned = item.value.compactMapValues { $0 }
                guard let data = try? JSONSerialization.data(
                    withJSONObject: cleaned,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                ) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            result.dematerializeItems()
            Task { @MainActor in
                onChange(rows)
            }
        }
    }

    // MARK: - Helpers

    private func requireInstance() throws -> Ditto {
        guard let ditto else {
            throw AppError.error(message: "Ditto is not open yet")
        }
        return ditto
    }

    /// Decodes query result items to Sendable models and dematerializes the
    /// items. `nonisolated static`: pure work, reachable from any executor.
    /// JSONSerialization (throws, catchable) is used rather than
    /// item.jsonData() (which traps on failure).
    nonisolated static func decodeItems<T: Decodable>(
        _ result: DittoQueryResult,
        as type: T.Type
    ) throws -> [T] {
        defer { result.dematerializeItems() }
        let decoder = JSONDecoder()
        return try result.items.map { item in
            let cleaned = item.value.compactMapValues { $0 }
            let data = try JSONSerialization.data(withJSONObject: cleaned)
            return try decoder.decode(T.self, from: data)
        }
    }
}

extension DittoQueryResult {
    /// Releases the native cursors backing this result's items (the SDK
    /// exposes dematerialize() per item, not per result).
    func dematerializeItems() {
        items.forEach { $0.dematerialize() }
    }
}
