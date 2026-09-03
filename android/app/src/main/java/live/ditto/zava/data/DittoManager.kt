package live.ditto.zava.data

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import com.ditto.kotlin.Ditto
import com.ditto.kotlin.DittoAuthenticationProvider
import com.ditto.kotlin.DittoFactory
import com.ditto.kotlin.DittoStoreObserver
import com.ditto.kotlin.DittoSyncSubscription
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import live.ditto.zava.model.AppError
import live.ditto.zava.model.BenchmarkRunResult
import live.ditto.zava.model.MulticastConfig
import live.ditto.zava.model.BenchmarkRunner
import live.ditto.zava.model.PreparedBenchmark
import live.ditto.zava.model.QueryPreparation
import java.io.File

/// The only Ditto access point in the app (1:1 port of the Swift reference's
/// `actor DittoManager`). Singleton object rather than Koin — the repo's
/// "no DI frameworks, one thin access point" convention (root AGENTS.md).
///
/// Contracts (mirrored from swift/…/DittoManager.swift):
/// - `open()` shares one in-flight task — DittoFactory.create never runs twice
///   concurrently against the same persistence dir.
/// - Store switches carry [selectionEpoch]; any step that suspends mid-switch
///   re-checks the epoch before mutating subscription state.
/// - Store ids must match ^[a-z0-9_\-]+$ before flowing into DQL or args.
/// - Errors surface to the AppState banner via the onError callback — never
///   to nowhere.
object DittoManager {
    private const val TAG = "DittoManager"

    private val mutex = Mutex()
    private var ditto: Ditto? = null

    /// Read on the Default dispatcher from the re-evict job — needs the
    /// visibility guarantee (@Volatile), not "the JIT probably flushes it".
    @Volatile
    var currentStoreId: String? = null
        private set
    private var sharedSubscriptions = mutableListOf<DittoSyncSubscription>()
    private var storeSubscriptions = mutableListOf<DittoSyncSubscription>()
    private var openJob: Deferred<Ditto>? = null

    /// Generation guard so open() only clears its OWN in-flight task.
    private var openGeneration = 0

    @Volatile
    private var selectionEpoch = 0
    private var reEvictJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private lateinit var appContext: Context

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** ^[a-z0-9_\-]+$ — the dataset's store id shape. */
    fun isValidStoreId(storeId: String): Boolean = QueryPreparation.isValidStoreId(storeId)

    @PublishedApi
    internal val json = Json {
        ignoreUnknownKeys = true
        // Explicit JSON nulls behave like absent keys (the Swift decode path
        // strips NSNulls); a null/absent required field then fails loudly.
        explicitNulls = false
    }

    // MARK: - Open / close

    /// Single in-flight open; on failure the state is torn down so a retry is
    /// clean. onError is invoked on the main thread.
    suspend fun open(config: DatabaseConfig, onError: (String) -> Unit): Ditto {
        ditto?.let { return it }
        openJob?.let { return it.await() }
        // Single-owner clearing with a generation guard: a failed/successful
        // open only ever clears its OWN task — a retry's in-flight task is
        // never clobbered.
        val generation = mutex.withLock { ++openGeneration }
        val job = scope.async { openAndConfigure(config, onError) }
        openJob = job
        return try {
            val instance = job.await()
            mutex.withLock { if (openGeneration == generation) openJob = null }
            instance
        } catch (e: Exception) {
            mutex.withLock { if (openGeneration == generation) openJob = null }
            throw e
        }
    }

    private suspend fun openAndConfigure(config: DatabaseConfig, onError: (String) -> Unit): Ditto {
        val dir = File(appContext.filesDir, "zava/ditto").apply { mkdirs() }
        val dittoConfig = config.makeDittoConfig(persistenceDirectory = dir.absolutePath)
        val instance = withContext(Dispatchers.IO) { DittoFactory.create(dittoConfig) }

        // Auth: development provider; capture the token BY VALUE (never the
        // manager) into the SDK-held handler. Login failures surface to the
        // AppState banner via onError — never to nowhere (the Swift reference
        // forwards these; the first Android cut dropped them).
        val token = config.developmentToken
        instance.auth?.expirationHandler = { d, _ ->
            try {
                d.auth?.login(token = token, provider = DittoAuthenticationProvider.development())
            } catch (e: Exception) {
                withContext(Dispatchers.Main) { onError("Ditto auth failed: ${e.localizedMessage}") }
            }
        }

        try {
            registerSharedSubscriptions(instance)
            createSupportingIndexes(instance)
            startSyncNow(instance)
        } catch (e: Exception) {
            // Never pin a half-initialized instance.
            runCatching { stopSyncNow(instance) }
            runCatching { withContext(Dispatchers.IO) { instance.close() } }
            sharedSubscriptions.forEach { it.close() }
            sharedSubscriptions.clear()
            mutex.withLock { ditto = null; openJob = null }
            throw e
        }
        mutex.withLock { ditto = instance }
        return instance
    }

    // MARK: - Subscriptions & indexes (DQL strings stay visible at the call site)

    private fun registerSharedSubscriptions(instance: Ditto) {
        if (sharedSubscriptions.isNotEmpty()) return
        sharedSubscriptions += listOf(
            // shared catalog (registered once)
            instance.sync.registerSubscription("SELECT * FROM stores"),
            instance.sync.registerSubscription("SELECT * FROM categories"),
            instance.sync.registerSubscription("SELECT * FROM products"),
            // subscription__customers_all — the whole directory (a walk-in could be anyone)
            instance.sync.registerSubscription("SELECT * FROM customers WHERE deleted = false"),
        )
    }

    private suspend fun createSupportingIndexes(instance: Ditto) {
        // App-namespaced zava_* names so the Query Runner's benchmark
        // postQueries (DROP INDEX on benchmark-named indexes) can never drop
        // the app's own indexes (PLAN §4.1). The lambda form of execute scopes
        // the result's cursor lifetime to the block (SDK-managed).
        for (statement in listOf(
            "CREATE INDEX IF NOT EXISTS zava_inventory_store ON inventory (_id.store_id)",
            "CREATE INDEX IF NOT EXISTS zava_orders_store ON orders (store_id, deleted)",
            "CREATE INDEX IF NOT EXISTS zava_order_items_store ON order_items (store_id, deleted)",
        )) {
            instance.store.execute(statement, emptyMap()) { }
        }
    }

    // MARK: - Store switch (epoch-guarded)

    /// Superseded switches simply RETURN (the latest pick wins). Failure
    /// path: if an EVICT throws mid-switch, the old store's subs are already
    /// closed and its data partially evicted — the old store no longer exists
    /// as a coherent target, so currentStoreId is cleared before rethrowing
    /// and the UI rolls back to the picker, not to a torn store.
    suspend fun applyStoreSelection(storeId: String) {
        if (!isValidStoreId(storeId)) throw AppError("Invalid store id '$storeId'")
        val instance = ditto ?: throw AppError("Ditto is not open yet")
        if (storeId == currentStoreId) return

        val epoch = mutex.withLock { ++selectionEpoch }
        Log.i(TAG, "store selection → $storeId: re-registering per-store subscriptions")

        storeSubscriptions.forEach { it.close() }
        storeSubscriptions.clear()

        // Local-only removal of the old store's slice (EVICT vs DELETE is a
        // teaching moment). Docs in flight can still land afterwards — hence
        // the re-evict pass below.
        try {
            for (collection in listOf("order_items", "orders", "inventory")) {
                instance.store.execute("EVICT FROM $collection WHERE store_id != :storeId", mapOf("storeId" to storeId)) { }
                if (selectionEpoch != epoch) return // superseded mid-evict
            }
        } catch (e: Exception) {
            currentStoreId = null
            throw e
        }
        if (selectionEpoch != epoch) return

        // The benchmark's subscription__* queries verbatim, parameterized.
        // Append as registered: a mid-sequence throw leaves the earlier subs
        // tracked (the next switch's close loop owns them), never leaked.
        storeSubscriptions += instance.sync.registerSubscription(
            "SELECT * FROM inventory WHERE _id.store_id = :storeId AND deleted = false",
            mapOf("storeId" to storeId),
        )
        storeSubscriptions += instance.sync.registerSubscription(
            "SELECT * FROM orders WHERE store_id = :storeId AND deleted = false",
            mapOf("storeId" to storeId),
        )
        storeSubscriptions += instance.sync.registerSubscription(
            "SELECT * FROM order_items WHERE store_id = :storeId AND deleted = false",
            mapOf("storeId" to storeId),
        )
        currentStoreId = storeId
        scheduleReEvict(storeId, epoch)
    }

    /// Docs already in flight from the cancelled subscription can land after
    /// the first EVICT; re-evict once things settle (3 s), unless superseded.
    private fun scheduleReEvict(storeId: String, epoch: Int) {
        reEvictJob?.cancel()
        reEvictJob = scope.launch {
            delay(3_000)
            if (selectionEpoch != epoch) return@launch
            Log.i(TAG, "re-evict pass for $storeId")
            for (collection in listOf("order_items", "orders", "inventory")) {
                // Re-check the epoch after every suspension, same discipline
                // as the primary switch path — a newer selection must not
                // watch the old pass evict ITS freshly-syncing rows.
                val instance = ditto
                if (selectionEpoch != epoch || instance == null) return@launch
                try {
                    instance.store.execute("EVICT FROM $collection WHERE store_id != :storeId", mapOf("storeId" to storeId)) { }
                } catch (e: Exception) {
                    Log.e(TAG, "re-evict failed for $collection: ${e.localizedMessage}")
                }
            }
        }
    }

    // MARK: - Sync funnels (the only sync.start/stop call sites)

    private suspend fun startSyncNow(instance: Ditto) = withContext(Dispatchers.IO) {
        instance.sync.start()
    }

    private suspend fun stopSyncNow(instance: Ditto) = withContext(Dispatchers.IO) {
        instance.sync.stop()
    }

    // MARK: - Multicast (beta) transport

    /// App-level Wi-Fi multicast lock, held while the multicast transport is
    /// enabled (pubsec-edgesync sidecar pattern: the SDK also holds its own
    /// engine-level lock via DittoMulticastLock; this one covers the process
    /// for the whole enabled period).
    private var wifiMulticastLock: WifiManager.MulticastLock? = null

    /// The multicast settings last applied to the live instance.
    var multicastConfig = MulticastConfig()
        private set

    /// Applies multicast settings LIVE (the SDK documents transportConfig as
    /// alterable at any time — no sync restart needed) and holds/releases the
    /// app-level Wi-Fi multicast lock. Throws if Ditto isn't open.
    fun setMulticastConfig(config: MulticastConfig) {
        val instance = ditto ?: throw AppError("Ditto is not open yet")
        instance.updateTransportConfig { transportConfig ->
            transportConfig.peerToPeer.multicastBeta.enabled = config.enabled
            transportConfig.peerToPeer.multicastBeta.groupAddress = config.groupAddress
            transportConfig.peerToPeer.multicastBeta.port = config.port.toUShort()
            transportConfig.peerToPeer.multicastBeta.interfaceName = config.interfaceName
        }
        multicastConfig = config
        if (config.enabled) acquireMulticastLock() else releaseMulticastLock()
        Log.i(
            TAG,
            if (config.enabled) {
                "multicast beta ENABLED (${config.groupAddress}:${config.port}" +
                    (config.interfaceName?.let { ", iface $it" } ?: "") + ")"
            } else {
                "multicast beta disabled"
            },
        )
    }

    private fun acquireMulticastLock() {
        if (wifiMulticastLock == null) {
            val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiMulticastLock = wifiManager?.createMulticastLock("zava-multicast")
                ?.apply { setReferenceCounted(false) }
        }
        wifiMulticastLock?.let { if (!it.isHeld) it.acquire() }
    }

    private fun releaseMulticastLock() {
        wifiMulticastLock?.let { if (it.isHeld) it.release() }
    }

    // MARK: - One-shot queries

    private fun requireInstance(): Ditto = ditto ?: throw AppError("Ditto is not open yet")

    /// The lambda form of execute scopes the result's cursor lifetime to the
    /// block — decode inside, dematerialize explicitly (the Swift contract).
    suspend fun <T> fetch(query: String, arguments: Map<String, Any?> = emptyMap(), decoder: (String) -> T): List<T> =
        requireInstance().store.execute(query, arguments) { result ->
            result.items.map { item ->
                val decoded = decoder(item.jsonString())
                item.dematerialize()
                decoded
            }
        }

    suspend inline fun <reified T> fetch(query: String, arguments: Map<String, Any?> = emptyMap()): List<T> =
        fetch(query, arguments) { json.decodeFromString<T>(it) }

    /// The timed unit for the Query Runner: execute + materialize row count,
    /// no row decoding (mirrors the benchmark harness).
    suspend fun executeReturningRowCount(query: String, arguments: Map<String, Any?> = emptyMap()): Int =
        requireInstance().store.execute(query, arguments) { result ->
            val count = result.items.size
            result.items.forEach { it.dematerialize() }
            count
        }

    // MARK: - Live observers (decode off-main, 100 ms coalesced delivery)

    fun <T> observe(
        query: String,
        arguments: Map<String, Any?> = emptyMap(),
        decode: (String) -> T,
        onDecodeError: ((String) -> Unit)? = null,
        onChange: (List<T>) -> Unit,
    ): DittoStoreObserver {
        val coalescer = ResultCoalescer(onChange = onChange)
        return requireInstance().store.registerObserver(query, arguments) { result ->
            try {
                val decoded = result.items.map { decode(it.jsonString()) }
                coalescer.enqueue(decoded)
            } catch (e: Exception) {
                if (onDecodeError != null) {
                    scope.launch(Dispatchers.Main) { onDecodeError("observer decode failed: ${e.localizedMessage}") }
                } else {
                    // Never silent: schema drift must not freeze a screen
                    // without a trace.
                    Log.e(TAG, "observer decode failed: ${e.localizedMessage}")
                }
            } finally {
                // Cursors release on EVERY path — a decode throw must not
                // strand them (the schema-drift case is exactly when we're
                // already in trouble).
                result.items.forEach { it.dematerialize() }
            }
            Unit
        }
    }

    inline fun <reified T> observe(
        query: String,
        arguments: Map<String, Any?> = emptyMap(),
        noinline onDecodeError: ((String) -> Unit)? = null,
        noinline onChange: (List<T>) -> Unit,
    ): DittoStoreObserver = observe(query, arguments, { json.decodeFromString<T>(it) }, onDecodeError, onChange)

    /// For `system:*` virtual collections: compact JSON with sorted keys, one
    /// string per row; observers parse on the main thread.
    fun observeRawJson(
        query: String,
        onChange: (List<String>) -> Unit,
    ): DittoStoreObserver {
        val coalescer = ResultCoalescer(onChange = onChange)
        return requireInstance().store.registerObserver(query, emptyMap()) { result ->
            try {
                val rows = result.items.map { item ->
                    val obj = json.parseToJsonElement(item.jsonString()) as? JsonObject
                    obj?.let { JsonObject(it.toSortedMap()).toString() } ?: "{}"
                }
                coalescer.enqueue(rows)
            } catch (e: Exception) {
                Log.e(TAG, "raw observer row failed: ${e.localizedMessage}")
            } finally {
                result.items.forEach { it.dematerialize() }
            }
            Unit
        }
    }

    // MARK: - Benchmark orchestration (Query Runner)

    suspend fun runBenchmark(prepared: PreparedBenchmark, iterations: Int): BenchmarkRunResult =
        BenchmarkRunner.runOrchestrated(prepared, iterations) { executeReturningRowCount(it) }
}
