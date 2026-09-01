package live.ditto.zava.data

import android.content.Context
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
    var currentStoreId: String? = null
        private set
    private var sharedSubscriptions = mutableListOf<DittoSyncSubscription>()
    private var storeSubscriptions = mutableListOf<DittoSyncSubscription>()
    private var openJob: Deferred<Ditto>? = null
    private var selectionEpoch = 0
    private var reEvictJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private lateinit var appContext: Context

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    val isOpen: Boolean get() = ditto != null
    val instance: Ditto? get() = ditto

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
        val job = scope.async { openAndConfigure(config, onError) }
        openJob = job
        return try {
            job.await()
        } catch (e: Exception) {
            mutex.withLock { openJob = null }
            throw e
        }
    }

    private suspend fun openAndConfigure(config: DatabaseConfig, onError: (String) -> Unit): Ditto {
        val dir = File(appContext.filesDir, "zava/ditto").apply { mkdirs() }
        val dittoConfig = config.makeDittoConfig(persistenceDirectory = dir.absolutePath)
        val instance = withContext(Dispatchers.IO) { DittoFactory.create(dittoConfig) }

        // Auth: development provider; capture the token BY VALUE (never the
        // manager) into the SDK-held handler.
        val token = config.developmentToken
        instance.auth?.expirationHandler = { d, _ ->
            d.auth?.login(token = token, provider = DittoAuthenticationProvider.development())
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

    suspend fun applyStoreSelection(storeId: String) {
        if (!isValidStoreId(storeId)) throw AppError("Invalid store id '$storeId'")
        val instance = ditto ?: return
        if (storeId == currentStoreId) return

        val epoch = mutex.withLock { ++selectionEpoch }
        Log.i(TAG, "store selection → $storeId: re-registering per-store subscriptions")

        storeSubscriptions.forEach { it.close() }
        storeSubscriptions.clear()

        // Local-only removal of the old store's slice (EVICT vs DELETE is a
        // teaching moment). Docs in flight can still land afterwards — hence
        // the re-evict pass below.
        for (collection in listOf("order_items", "orders", "inventory")) {
            instance.store.execute("EVICT FROM $collection WHERE store_id != :storeId", mapOf("storeId" to storeId)) { }
            if (selectionEpoch != epoch) return // superseded mid-evict
        }
        if (selectionEpoch != epoch) return

        // The benchmark's subscription__* queries verbatim, parameterized.
        storeSubscriptions += listOf(
            instance.sync.registerSubscription(
                "SELECT * FROM inventory WHERE _id.store_id = :storeId AND deleted = false",
                mapOf("storeId" to storeId),
            ),
            instance.sync.registerSubscription(
                "SELECT * FROM orders WHERE store_id = :storeId AND deleted = false",
                mapOf("storeId" to storeId),
            ),
            instance.sync.registerSubscription(
                "SELECT * FROM order_items WHERE store_id = :storeId AND deleted = false",
                mapOf("storeId" to storeId),
            ),
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
            val instance = ditto ?: return@launch
            if (selectionEpoch != epoch) return@launch
            Log.i(TAG, "re-evict pass for $storeId")
            for (collection in listOf("order_items", "orders", "inventory")) {
                runCatching {
                    instance.store.execute("EVICT FROM $collection WHERE store_id != :storeId", mapOf("storeId" to storeId)) { }
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
                result.items.forEach { it.dematerialize() }
                coalescer.enqueue(decoded)
            } catch (e: Exception) {
                onDecodeError?.let { handler ->
                    scope.launch(Dispatchers.Main) { handler("observer decode failed: ${e.localizedMessage}") }
                }
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
            val rows = result.items.map { item ->
                val obj = json.parseToJsonElement(item.jsonString()) as? JsonObject
                obj?.let { JsonObject(it.toSortedMap()).toString() } ?: "{}"
            }
            result.items.forEach { it.dematerialize() }
            coalescer.enqueue(rows)
            Unit
        }
    }

    // MARK: - Benchmark orchestration (Query Runner)

    suspend fun runBenchmark(prepared: PreparedBenchmark, iterations: Int): BenchmarkRunResult =
        BenchmarkRunner.runOrchestrated(prepared, iterations) { executeReturningRowCount(it) }
}
