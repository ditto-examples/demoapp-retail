package live.ditto.zava

import live.ditto.zava.model.BenchmarkCatalog
import live.ditto.zava.model.Paging
import live.ditto.zava.model.QueryPreparation
import live.ditto.zava.ui.Formatters
import live.ditto.zava.ui.orders.OrdersState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/// Ports of the Swift reference's pure-logic unit tests
/// (ZavaRetailLogicTests + the runner tests in ZavaRetailTests).

class LogicTests {

    // MARK: - Paging

    @Test
    fun pageQueryInterpolatesLimitOffset() {
        val q = Paging.pageQuery("SELECT * FROM orders", "order_date DESC, _id DESC", 3, 25)
        assertEquals("SELECT * FROM orders ORDER BY order_date DESC, _id DESC LIMIT 25 OFFSET 50", q)
    }

    @Test
    fun clampPageKeepsInRange() {
        assertEquals(3, Paging.clampPage(3, 100, 25))
        assertEquals(4, Paging.clampPage(99, 100, 25))
        assertEquals(1, Paging.clampPage(-3, 100, 25))
        assertEquals(1, Paging.clampPage(5, 0, 25))
    }

    // MARK: - Store id validation

    @Test
    fun isValidStoreId() {
        assertTrue(QueryPreparation.isValidStoreId("store_seattle"))
        assertTrue(QueryPreparation.isValidStoreId("store-online_2"))
        assertFalse(QueryPreparation.isValidStoreId("store'; DROP TABLE stores; --"))
        assertFalse(QueryPreparation.isValidStoreId(""))
    }

    // MARK: - Orders search

    @Test
    fun ordersSearchQueryShape() {
        val q = OrdersState.searchQuery
        assertTrue(q.contains("INNER JOIN customers AS c ON o.customer_id = c._id"))
        assertTrue(q.contains("o.order_id ILIKE :like"))
        assertTrue(q.contains("c.first_name ILIKE :like"))
        assertTrue(q.contains("c.last_name ILIKE :like"))
        assertTrue(q.contains("o.store_id = :storeId"))
        assertTrue(q.contains("ORDER BY o.order_date DESC, o._id DESC"))
        assertTrue(q.contains("LIMIT 50"))
        assertFalse("no denormalized fields in the join shape", q.contains("customer_name"))
    }

    @Test
    fun ordersSearchTermSanitization() {
        assertEquals("20250115", OrdersState.sanitizedSearchTerm("  20250115  "))
        assertEquals("20250115_0001", OrdersState.sanitizedSearchTerm("#20250115_0001"))
        assertEquals("", OrdersState.sanitizedSearchTerm("##"))
        assertEquals("", OrdersState.sanitizedSearchTerm("   "))
        assertEquals("2025%", OrdersState.sanitizedSearchTerm("2025%")) // wildcards pass through
    }

    // MARK: - Orders "recent" cutoff anchors to the data, not the clock

    @Test
    fun cutoffDateAnchorsToData() {
        val cutoff = OrdersState.cutoffDate("2025-06-27T18:20:00Z", 30)
        assertTrue(cutoff!!.startsWith("2025-05-28"))
    }

    @Test
    fun cutoffDateRejectsGarbage() {
        assertEquals(null, OrdersState.cutoffDate("not a date", 30))
    }

    // MARK: - Customers where clause decision

    @Test
    fun customersWhereClause() {
        val store = live.ditto.zava.ui.customers.CustomersState.storeWhere
        val directory = live.ditto.zava.ui.customers.CustomersState.directoryWhere
        assertEquals(directory, live.ditto.zava.ui.customers.CustomersState.whereClause(false, "store_seattle"))
        assertEquals(store, live.ditto.zava.ui.customers.CustomersState.whereClause(true, "store_seattle"))
        assertEquals(directory, live.ditto.zava.ui.customers.CustomersState.whereClause(true, null))
    }

    // MARK: - Formatters

    @Test
    fun usdFormats() {
        assertEquals("$1,234.50", Formatters.usd(1234.5))
        assertEquals("$0.00", Formatters.usd(0.0))
    }

    @Test
    fun dateTimeSurgery() {
        assertEquals("2025-06-27 18:20", Formatters.dateTime("2025-06-27T18:20:00Z"))
        assertEquals("short", Formatters.dateTime("short"))
    }

    // MARK: - Benchmark catalog (loads the real bundled file)

    @Test
    fun catalogLoadsAndGroups() {
        val file = File("../shared/benchmarks.json").takeIf { it.exists() }
            ?: File("../../shared/benchmarks.json")
        assertTrue("benchmarks.json must be reachable from the test working dir", file.exists())
        val catalog = BenchmarkCatalog.parse(file.readText())
        assertEquals(96, catalog.entries.size)
        val collections = catalog.groups.map { it.collection }
        assertTrue(collections.contains("orders"))
        assertTrue(collections.contains("order_items"))
        assertTrue("the retail-joins catalog's JOIN groups must ship in the bundle",
            collections.contains("joins"))
        // Groups and entries are sorted.
        assertEquals(collections.sorted(), collections)
    }
}
