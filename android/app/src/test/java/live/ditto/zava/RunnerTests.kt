package live.ditto.zava

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import live.ditto.zava.model.BenchmarkRunner
import live.ditto.zava.model.BenchmarkEntry
import live.ditto.zava.model.BenchmarkStats
import live.ditto.zava.model.PreparedBenchmark
import live.ditto.zava.model.QueryPreparation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/// Ports of the Swift reference's Query Runner tests (store substitution,
/// mutating-run transforms, stats math, orchestration order/cleanup).

class RunnerTests {

    private fun entry(
        query: String,
        category: String = "SELECT",
        preQueries: List<String>? = null,
        postQueries: List<String>? = null,
    ) = BenchmarkEntry(query = query, category = category, preQueries = preQueries, postQueries = postQueries)

    // MARK: - Store substitution

    @Test
    fun storeSubstitution() {
        val e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false")
        val prepared = QueryPreparation.prepare("orders__select__by_store", e, storeId = "store_tacoma", runId = "testrun1")
        assertTrue(prepared.query.contains("store_id = 'store_tacoma'"))
        assertFalse(prepared.query.contains("store_seattle"))
        assertTrue("substitution must be visible in the UI", prepared.substitutions.isNotEmpty())
    }

    @Test
    fun noSubstitutionWhenSeattleSelected() {
        val e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false")
        val prepared = QueryPreparation.prepare("x", e, storeId = "store_seattle", runId = "testrun1")
        assertTrue(prepared.query.contains("store_seattle"))
        assertTrue(prepared.substitutions.isEmpty())
    }

    @Test
    fun invalidStoreIdSkipsSubstitution() {
        val e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle'")
        val prepared = QueryPreparation.prepare("x", e, storeId = "store'; --", runId = "r1")
        assertTrue("an unsafe store id must not be interpolated into DQL", prepared.query.contains("store_seattle"))
        assertTrue(prepared.substitutions.any { it.contains("doesn't match") })
    }

    // MARK: - Mutating runs

    @Test
    fun mutatingRunGetsFreshIdsAndDeleteCleanup() {
        val e = entry(
            query = "INSERT INTO customers DOCUMENTS(deserialize_json('{\"_id\":\"bench-cust-insert-uuid\"}')) ON ID CONFLICT DO UPDATE",
            category = "INSERT",
            postQueries = listOf("EVICT FROM customers WHERE _id = 'bench-cust-insert-uuid'"),
        )
        val prepared = QueryPreparation.prepare("customers__insert__one", e, storeId = "store_seattle", runId = "run42")
        assertTrue(prepared.isMutating)
        assertTrue(prepared.query.contains("bench-run42-cust-insert-uuid"))
        assertEquals(listOf("DELETE FROM customers WHERE _id = 'bench-run42-cust-insert-uuid'"), prepared.postQueries)
    }

    @Test
    fun evictBenchmarkGetsPropagatingCleanupAppended() {
        val e = entry(
            query = "EVICT FROM customers WHERE _id = 'bench-cust-evict-uuid'",
            category = "EVICT",
            preQueries = listOf("INSERT INTO customers DOCUMENTS(deserialize_json('{\"_id\":\"bench-cust-evict-uuid\"}'))"),
        )
        val prepared = QueryPreparation.prepare("customers__evict__by_id", e, storeId = "store_seattle", runId = "run7")
        assertEquals(listOf("DELETE FROM customers WHERE _id = 'bench-run7-cust-evict-uuid'"), prepared.postQueries)
        // preQueries get the same transform (dropping that map must fail loudly).
        assertEquals(
            listOf("INSERT INTO customers DOCUMENTS(deserialize_json('{\"_id\":\"bench-run7-cust-evict-uuid\"}'))"),
            prepared.preQueries,
        )
    }

    @Test
    fun evictCleanupCompositeId() {
        val e = entry(
            query = "EVICT FROM inventory WHERE _id = {'store_id': 'store_seattle', 'product_id': 'bench-prod'}",
            category = "EVICT",
        )
        val cleanup = QueryPreparation.evictCleanup(e) { it.replace("bench-", "bench-r2-") }
        assertEquals(
            "DELETE FROM inventory WHERE _id = {'store_id': 'store_seattle', 'product_id': 'bench-r2-prod'}",
            cleanup,
        )
    }

    @Test
    fun evictCleanupBulkOrderId() {
        // The joins catalog's bulk EVICT predicates on order_id, not _id
        // (order_items__evict__bulk_by_order) — cleanup must still derive.
        val e = entry(
            query = "EVICT FROM order_items WHERE order_id = 'bench-bulk-evict'",
            category = "EVICT",
        )
        val cleanup = QueryPreparation.evictCleanup(e) { it.replace("bench-", "bench-r9-") }
        assertEquals("DELETE FROM order_items WHERE order_id = 'bench-r9-bulk-evict'", cleanup)
    }

    @Test
    fun upsertIsMutating() {
        // UPSERT writes bench docs — it needs the confirm gate + id suffixing.
        val e = entry(
            query = "INSERT INTO orders DOCUMENTS(deserialize_json('{\"_id\":\"bench-order-ups\"}')) ON ID CONFLICT DO UPDATE",
            category = "UPSERT",
            postQueries = listOf("EVICT FROM orders WHERE _id = 'bench-order-ups'"),
        )
        val prepared = QueryPreparation.prepare("orders__upsert__force_update", e, storeId = "store_seattle", runId = "run5")
        assertTrue(prepared.isMutating)
        assertTrue(prepared.query.contains("bench-run5-order-ups"))
        assertEquals(listOf("DELETE FROM orders WHERE _id = 'bench-run5-order-ups'"), prepared.postQueries)
    }

    @Test
    fun evictCleanupIgnoresNonEvict() {
        assertEquals(null, QueryPreparation.evictCleanup(entry("SELECT * FROM stores")) { it })
    }

    @Test
    fun readOnlyBenchmarksAreUntouched() {
        val e = entry("SELECT * FROM stores")
        val prepared = QueryPreparation.prepare("stores__select__all", e, storeId = "store_tacoma", runId = "x")
        assertEquals("SELECT * FROM stores", prepared.query)
        assertTrue(prepared.preQueries.isEmpty())
        assertTrue(prepared.postQueries.isEmpty())
        assertTrue(prepared.substitutions.isEmpty())
    }

    // MARK: - Stats

    @Test
    fun benchmarkStats() {
        val stats = BenchmarkStats.of(listOf(1.0, 2.0, 3.0, 4.0, 5.0))
        assertEquals(3.0, stats.meanMs, 0.0001)
        assertEquals(3.0, stats.medianMs, 0.0001)
        assertEquals(5.0, stats.p95Ms, 0.0001)
        assertEquals(1.0, stats.minMs, 0.0001)
        assertEquals(5.0, stats.maxMs, 0.0001)
    }

    @Test
    fun benchmarkStatsEmpty() {
        val stats = BenchmarkStats.of(emptyList())
        assertEquals(0.0, stats.meanMs, 0.0001)
        assertEquals(0.0, stats.p95Ms, 0.0001)
    }

    // MARK: - Orchestration

    private fun prepared(
        pre: List<String> = emptyList(),
        query: String = "SELECT 1",
        post: List<String> = emptyList(),
        category: String = "SELECT",
    ) = PreparedBenchmark(
        name = "test",
        category = category,
        isMutating = category in setOf("INSERT", "UPDATE", "DELETE", "EVICT"),
        preQueries = pre,
        query = query,
        postQueries = post,
        substitutions = emptyList(),
    )

    @Test
    fun orchestrationOrder() = runTest {
        val calls = mutableListOf<String>()
        val result = BenchmarkRunner.runOrchestrated(
            prepared(pre = listOf("CREATE INDEX a"), post = listOf("DROP INDEX a")),
            iterations = 3,
        ) { query ->
            calls += query
            7
        }
        assertEquals(listOf("CREATE INDEX a", "SELECT 1", "SELECT 1", "SELECT 1", "DROP INDEX a"), calls)
        assertEquals(3, result.iterations)
        assertEquals(7, result.resultCount)
    }

    /// Navigating away mid-run cancels the calling coroutine — cleanup must
    /// STILL run (the synthetic doc must not stay on Big Peer). The
    /// delay-before-record ordering makes this test fail against the pre-fix
    /// runner (the cancelled context throws before cleanup is ever recorded).
    @Test
    fun orchestrationRunsCleanupOnCancellation() = runTest {
        val calls = mutableListOf<String>()
        val job = launch {
            BenchmarkRunner.runOrchestrated(
                prepared(query = "INSERT timed", post = listOf("DELETE cleanup"), category = "INSERT"),
                iterations = 50,
            ) { query ->
                kotlinx.coroutines.delay(10) // throws if the calling coroutine is cancelled
                calls += query
                1
            }
        }
        kotlinx.coroutines.delay(45) // a few iterations in
        job.cancel()
        job.join()
        assertTrue("cleanup must run even when the run is cancelled mid-flight", calls.contains("DELETE cleanup"))
    }

    @Test
    fun orchestrationRunsCleanupOnFailure() = runTest {
        val calls = mutableListOf<String>()
        var timedCalls = 0
        try {
            BenchmarkRunner.runOrchestrated(
                prepared(pre = listOf("INSERT seed"), query = "INSERT timed", post = listOf("DELETE cleanup"), category = "INSERT"),
                iterations = 5,
            ) { query ->
                if (query == "INSERT timed") {
                    timedCalls++
                    if (timedCalls == 3) throw RuntimeException("boom")
                }
                calls += query
                1
            }
            fail("iteration error must be rethrown after cleanup")
        } catch (e: RuntimeException) {
            assertEquals("boom", e.message)
        }
        assertEquals(listOf("INSERT seed", "INSERT timed", "INSERT timed", "DELETE cleanup"), calls)
    }
}
