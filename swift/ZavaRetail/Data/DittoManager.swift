import DittoSwift
import Foundation
import OSLog

/// The single owner of the app's Ditto instance (edge-studio pattern,
/// PLAN §1.3): an actor singleton. All Ditto access flows through here.
///
/// Swift 6 concurrency design:
/// - The actor owns mutable state (instance, subscriptions, selection).
/// - Callbacks handed to the SDK are `@Sendable` — they capture *values*
///   (Sendable models / strings), never `self` or other non-Sendable state.
/// - Observer delivery happens on a serial utility queue; decoded Sendable
///   models hop to the main actor for UI state, latest-wins coalesced at
///   100 ms so a sync storm can't head-of-line block the queue.
/// - `open()` shares one in-flight task (no double-open race), and store
///   switches carry an epoch so an interrupted switch can't leave stale
///   subscriptions behind.
actor DittoManager {
    static let shared = DittoManager()
    static let log = Logger(subsystem: "live.ditto.zava", category: "ditto")
    private init() {}

    private(set) var ditto: Ditto?
    /// The store the subscriptions actually serve — AppState reads this to
    /// roll its UI back when a switch fails midway.
    private(set) var currentStoreId: String?

    private var sharedSubscriptions: [DittoSyncSubscription] = []
    private var storeSubscriptions: [DittoSyncSubscription] = []
    private var openTask: Task<Ditto, Error>?
    /// Generation guard so open() only clears its OWN in-flight task.
    private var openGeneration = 0
    private var selectionEpoch = 0
    private var reEvictTask: Task<Void, Never>?

    /// Serial queue for observer delivery — heavy JSON decode work must not
    /// run on the main thread (the SDK's default `deliverOn`).
    private static let observerDeliveryQueue = DispatchQueue(
        label: "live.ditto.zava.observerDelivery",
        qos: .utility
    )

    /// Store ids flow into DQL as string literals (Query Runner store
    /// substitution) and as :storeId args. Dataset invariant: lowercase
    /// letters/digits/underscore/dash. Enforced here and in QueryPreparation.
    nonisolated static func isValidStoreId(_ storeId: String) -> Bool {
        storeId.range(of: #"^[a-z0-9_\-]+$"#, options: .regularExpression) != nil
    }

    // MARK: - Open / close

    /// Opens the Ditto instance exactly once per process: all callers share a
    /// single in-flight open task, so iPad multi-window (two scenes booting
    /// AppState at once) can't race two `Ditto.open` calls against the same
    /// persistence directory. A failed open tears the half-initialized
    /// instance down so a later call retries cleanly instead of returning a
    /// broken one.
    @discardableResult
    func open(
        config: DatabaseConfig,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Ditto {
        if let ditto {
            return ditto
        }
        if let openTask {
            return try await openTask.value
        }

        // Single-owner clearing with a generation guard: a failed/successful
        // open only ever clears its OWN task — a retry's in-flight task is
        // never clobbered (adversarial review: the catch used to clear
        // unconditionally, and openAndConfigure's catch cleared too, so two
        // owners could drop a newer task's handle).
        openGeneration += 1
        let generation = openGeneration
        let task = Task { try await self.openAndConfigure(config: config, onError: onError) }
        openTask = task
        do {
            let instance = try await task.value
            if openGeneration == generation {
                openTask = nil
            }
            return instance
        } catch {
            if openGeneration == generation {
                openTask = nil
            }
            throw error
        }
    }

    private func openAndConfigure(
        config: DatabaseConfig,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Ditto {
        let persistenceDirectory = try Self.persistenceDirectory()
        let dittoConfig = try config.makeDittoConfig(persistenceDirectory: persistenceDirectory)
        // The single access point — the inline disable IS the choke-point discipline.
        // swiftlint:disable:next ditto_open_choke_point
        let instance = try await Ditto.open(config: dittoConfig)

        // Capture only the values needed by the closure to avoid retaining
        // the DittoManager actor through the SDK-held expirationHandler.
        let token = config.developmentToken
        instance.auth?.expirationHandler = { dittoInstance, _ in
            dittoInstance.auth?.login(token: token, provider: .development) { _, error in
                if let error {
                    Task { @MainActor in
                        onError("Ditto auth failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        do {
            try registerSharedSubscriptions(on: instance)
            try await createSupportingIndexes(on: instance)
            try await Self.startSyncNow(instance)
        } catch {
            // Don't pin a half-initialized instance behind the early-return
            // guard: stop sync, cancel whatever registered, drop the
            // reference (ARC releases the SDK instance), and let the next
            // open() retry from scratch. openTask clearing stays with open().
            await Self.stopSyncNow(instance)
            sharedSubscriptions.forEach { $0.cancel() }
            sharedSubscriptions = []
            ditto = nil
            throw error
        }
        ditto = instance
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
        // Register one at a time INTO the tracked list: if a registration
        // throws, the already-registered ones are tracked (and cancelled by
        // the caller's teardown) rather than leaked as anonymous live subs.
        try sharedSubscriptions.append(ditto.sync.registerSubscription(query: "SELECT * FROM stores"))
        try sharedSubscriptions.append(ditto.sync.registerSubscription(query: "SELECT * FROM categories"))
        try sharedSubscriptions.append(ditto.sync.registerSubscription(query: "SELECT * FROM products"))
        // subscription__customers_all: the full customer directory — a
        // walk-in could be anyone, so devices hold all of them.
        try sharedSubscriptions.append(ditto.sync.registerSubscription(
            query: "SELECT * FROM customers WHERE deleted = false"
        ))
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
    ///
    /// Concurrency: the EVICT awaits suspend, so a second selection can arrive
    /// mid-switch. Each call bumps `selectionEpoch`; after every suspension a
    /// stale call bails out BEFORE registering anything — superseded switches
    /// simply RETURN (the latest pick wins; there is nothing to roll back).
    ///
    /// Failure path: if an EVICT throws mid-switch, the old store's subs are
    /// already cancelled and its data partially evicted — the old store no
    /// longer exists as a coherent target, so `currentStoreId` is cleared
    /// before rethrowing and the UI rolls back to the picker (from which any
    /// selection starts clean) instead of to a torn store.
    func applyStoreSelection(_ storeId: String) async throws {
        guard Self.isValidStoreId(storeId) else {
            throw AppError.error(message: "Invalid store id '\(storeId)'")
        }
        guard let ditto else {
            throw AppError.error(message: "Ditto is not open yet")
        }
        guard storeId != currentStoreId else { return }
        selectionEpoch += 1
        let epoch = selectionEpoch
        Self.log.info("store selection → \(storeId, privacy: .public): re-registering per-store subscriptions")

        for subscription in storeSubscriptions {
            subscription.cancel()
        }
        storeSubscriptions = []

        // Evict data from any previous store. All three per-store collections
        // carry a top-level store_id (inventory has both that and the
        // composite _id), so one simple predicate works everywhere.
        do {
            for collection in ["order_items", "orders", "inventory"] {
                try await ditto.store.execute(
                    query: "EVICT FROM \(collection) WHERE store_id != :storeId",
                    arguments: ["storeId": storeId]
                ).dematerializeItems()
                guard selectionEpoch == epoch else { return } // superseded mid-evict
            }
        } catch {
            currentStoreId = nil
            throw error
        }

        guard selectionEpoch == epoch else { return } // superseded before registering
        // Append as registered: a mid-list throw leaves the earlier subs
        // tracked (the next switch's cancel loop owns them), never leaked.
        try storeSubscriptions.append(ditto.sync.registerSubscription(
            query: "SELECT * FROM inventory WHERE _id.store_id = :storeId AND deleted = false",
            arguments: ["storeId": storeId]
        ))
        try storeSubscriptions.append(ditto.sync.registerSubscription(
            query: "SELECT * FROM orders WHERE store_id = :storeId AND deleted = false",
            arguments: ["storeId": storeId]
        ))
        try storeSubscriptions.append(ditto.sync.registerSubscription(
            query: "SELECT * FROM order_items WHERE store_id = :storeId AND deleted = false",
            arguments: ["storeId": storeId]
        ))
        currentStoreId = storeId
        scheduleReEvict(storeId: storeId, epoch: epoch)
    }

    /// PLAN §4.1 hardening: docs already in flight from the cancelled
    /// subscription can land AFTER the first EVICT and linger. A best-effort
    /// second pass runs after a short settle window (the cancelled session
    /// unwinds in that time); it's cancelled if a newer selection intervenes.
    private func scheduleReEvict(storeId: String, epoch: Int) {
        reEvictTask?.cancel()
        reEvictTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await reEvictIfCurrent(storeId: storeId, epoch: epoch)
        }
    }

    private func reEvictIfCurrent(storeId: String, epoch: Int) async {
        guard selectionEpoch == epoch, ditto != nil else { return }
        Self.log.info("re-evict pass for \(storeId, privacy: .public)")
        for collection in ["order_items", "orders", "inventory"] {
            // Re-check the epoch after every suspension, same discipline as
            // the primary switch path: a newer selection must not watch the
            // old pass evict ITS freshly-syncing rows.
            guard selectionEpoch == epoch, let ditto else { return }
            do {
                try await ditto.store.execute(
                    query: "EVICT FROM \(collection) WHERE store_id != :storeId",
                    arguments: ["storeId": storeId]
                ).dematerializeItems()
            } catch {
                Self.log.error("re-evict failed for \(collection): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Sync funnels (edge-studio pattern)

    /// The ONLY paths to sync.start()/stop() — concentrated so the call site
    /// is greppable and the SDK call runs off the caller's executor (the
    /// detached utility task avoids a priority inversion when called from the
    /// main actor).
    nonisolated static func startSyncNow(_ ditto: Ditto) async throws {
        try await Task.detached(priority: .utility) {
            // The single funnel — the inline disable IS the choke-point discipline.
            // swiftlint:disable:next sync_start_choke_point
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

    /// Runs a prepared benchmark against the live store (the actor's execute).
    func runBenchmark(
        _ prepared: PreparedBenchmark,
        iterations: Int
    ) async throws -> BenchmarkRunResult {
        try await Self.runBenchmarkOrchestrated(prepared, iterations: iterations) { query in
            try await self.executeReturningRowCount(query)
        }
    }

    /// The orchestration, decoupled from the SDK for tests (edge-studio's
    /// seam discipline): preQueries once (index create / seed doc), N timed
    /// iterations, postQueries once — even when a timed iteration throws.
    /// A cleanup failure never masks the real iteration error.
    /// Timing includes execution only, never rendering — the same unit the
    /// benchmark harness measures.
    nonisolated static func runBenchmarkOrchestrated(
        _ prepared: PreparedBenchmark,
        iterations: Int,
        execute: @Sendable @escaping (String) async throws -> Int
    ) async throws -> BenchmarkRunResult {
        for query in prepared.preQueries {
            _ = try await execute(query)
        }
        var durationsMs: [Double] = []
        durationsMs.reserveCapacity(iterations)
        var rowCount = 0
        var iterationError: Error?
        for _ in 0 ..< iterations {
            let start = ContinuousClock.now
            do {
                rowCount = try await execute(prepared.query)
                let elapsed = start.duration(to: ContinuousClock.now)
                let seconds = Double(elapsed.components.seconds)
                let attos = Double(elapsed.components.attoseconds)
                durationsMs.append(seconds * 1000 + attos / 1e15)
            } catch {
                iterationError = error
                break
            }
        }
        // Cleanup ALWAYS runs (a failed timed iteration must not strand the
        // synthetic doc or leave a benchmark index behind) — and even when the
        // CALLING task was cancelled mid-run (navigating away from a mutating
        // benchmark): the unstructured child task does not inherit
        // cancellation, so the DELETE still lands and Big Peer stays clean.
        // A cleanup error never masks the iteration error.
        let cleanupError: Error? = await Task { () -> Error? in
            var cleanupError: Error?
            for query in prepared.postQueries {
                do {
                    _ = try await execute(query)
                } catch {
                    cleanupError = error
                }
            }
            return cleanupError
        }.value
        if let iterationError {
            throw iterationError
        }
        if let cleanupError {
            throw cleanupError
        }
        return BenchmarkRunResult(
            iterations: durationsMs.count,
            stats: BenchmarkStats(durationsMs: durationsMs),
            resultCount: rowCount
        )
    }

    // MARK: - Observers

    /// Registers a store observer: results are decoded on the serial delivery
    /// queue (cursors dematerialized immediately), then latest-wins coalesced
    /// at 100 ms before hopping to the main actor — so a 25K-row customers
    /// sync storm can't make full decodes queue up behind each other.
    ///
    /// - Parameter onDecodeError: schema drift surfaces here instead of as a
    ///   silent empty list.
    func observe<T: Decodable & Sendable>(
        _ query: String,
        arguments: [String: Sendable]? = nil,
        as type: T.Type,
        onChange: @escaping @MainActor @Sendable ([T]) -> Void,
        onDecodeError: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> DittoStoreObserver {
        let ditto = try requireInstance()
        let args = arguments?.mapValues { $0 as Any? }
        let coalescer = ResultCoalescer<[T]>(onChange: onChange)
        return try ditto.store.registerObserver(
            query: query,
            arguments: args,
            deliverOn: Self.observerDeliveryQueue
        ) { result in
            // This closure is @Sendable and runs on the delivery queue. It
            // captures only `coalescer` (a locked box) and Sendable values.
            do {
                let decoded = try Self.decodeItems(result, as: type)
                coalescer.enqueue(decoded)
            } catch {
                if let onDecodeError {
                    let message = "observer decode failed: \(error.localizedDescription)"
                    Task { @MainActor in onDecodeError(message) }
                } else {
                    // Never silent: schema drift must not freeze a screen
                    // without a trace (adversarial review — the hook had zero
                    // call sites).
                    Self.log.error("observer decode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// JSON-row variant for the system:* collections (no Codable model).
    /// Delivers one compact-JSON string per row (Sendable), coalesced like
    /// the typed variant; observers parse on the main actor.
    func observeRawJSON(
        _ query: String,
        onChange: @escaping @MainActor @Sendable ([String]) -> Void
    ) async throws -> DittoStoreObserver {
        let ditto = try requireInstance()
        let coalescer = ResultCoalescer<[String]>(onChange: onChange)
        return try ditto.store.registerObserver(
            query: query,
            deliverOn: Self.observerDeliveryQueue
        ) { result in
            // @Sendable closure on the delivery queue; captures `coalescer` only.
            let rows: [String] = result.items.compactMap { item in
                let cleaned = item.value.compactMapValues { $0 }
                guard let data = try? JSONSerialization.data(
                    withJSONObject: cleaned,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                ) else { return nil }
                return String(bytes: data, encoding: .utf8) ?? ""
            }
            result.dematerializeItems()
            coalescer.enqueue(rows)
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

/// Latest-wins coalescer for observer emissions (edge-studio's 100 ms flush
/// pattern). Enqueued on the serial delivery queue; flushed to the main actor
/// at most once per interval — during an initial-sync storm the UI sees the
/// settled state, not every intermediate commit.
///
/// `@unchecked Sendable` contract: ALL mutable state (`pending`,
/// `flushScheduled`) is guarded by `lock`; the flush always hops through a
/// fresh `Task`. Mutations never race because the lock is held for every
/// read-modify-write.
final class ResultCoalescer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: T?
    private var flushScheduled = false
    private let flushInterval: Duration
    private let onChange: @MainActor @Sendable (T) -> Void

    init(
        flushInterval: Duration = .milliseconds(100),
        onChange: @escaping @MainActor @Sendable (T) -> Void
    ) {
        self.flushInterval = flushInterval
        self.onChange = onChange
    }

    func enqueue(_ value: T) {
        lock.lock()
        pending = value
        let shouldSchedule = !flushScheduled
        if shouldSchedule {
            flushScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        let interval = flushInterval
        Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        lock.lock()
        let value = pending
        pending = nil
        flushScheduled = false
        lock.unlock()
        guard let value else { return }
        Task { @MainActor [onChange] in
            onChange(value)
        }
    }
}
