package live.ditto.zava.ui.orders

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ditto.kotlin.DittoStoreObserver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import live.ditto.anvil.material3.DittoColors
import live.ditto.anvil.material3.DittoMonoFontFamily
import live.ditto.zava.data.DittoManager
import live.ditto.zava.model.CountRow
import live.ditto.zava.model.OrderLineRow
import live.ditto.zava.model.OrderSummaryRow
import live.ditto.zava.model.Paging
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.Formatters
import live.ditto.zava.ui.components.DittoBadge
import live.ditto.zava.ui.components.DittoBadgeStatus
import live.ditto.zava.ui.components.DittoCard
import live.ditto.zava.ui.components.PaginationBar
import live.ditto.zava.ui.components.PublishScreenInfo
import live.ditto.zava.ui.components.SectionHeader
import live.ditto.zava.ui.components.SkeletonRows
import live.ditto.zava.ui.components.ZavaSearchField
import java.time.Instant
import java.time.temporal.ChronoUnit

/// The orders list is a live, PAGED store observer over an INNER JOIN
/// (orders ⨝ customers — PLAN §4.2.2): the page slice is
/// `ORDER BY o.order_date DESC LIMIT pageSize OFFSET (page-1)*pageSize` and
/// the total comes from a COUNT observer over the same join — both
/// live-update as sync runs. The join replaces v5.0's denormalized
/// `orders.customer_name`; the normalized dataset carries customer ids only.
/// The "recent" filter anchors to max(order_date) in the local store — the
/// dataset ends 2025-06-27, so a device-clock-relative filter would show
/// zero rows.
class OrdersState {
    var orders by mutableStateOf<List<OrderSummaryRow>>(emptyList())
    var totalCount by mutableStateOf(0)
    var page by mutableStateOf(1)
    var pageSize by mutableStateOf(25)
    var recentOnly by mutableStateOf(false)

    /// The exact query currently observed — shown verbatim in the info sheet
    /// (with the resolved cutoff substituted, not a template).
    var activeQuery by mutableStateOf("")
    var error by mutableStateOf<String?>(null)

    /// Search (partial order number or customer name) — one-shot
    /// case-insensitive ILIKE queries with 500 ms debounce; the paged observer
    /// drives the list otherwise.
    var searchText by mutableStateOf("")
    var searchResults by mutableStateOf<List<OrderSummaryRow>?>(null)
    val isSearching: Boolean get() = searchResults != null
    val visibleOrders: List<OrderSummaryRow> get() = searchResults ?: orders

    private var pageObserver: DittoStoreObserver? = null
    private var countObserver: DittoStoreObserver? = null
    private var lastStoreId: String? = null

    /// Restart serialization: every restart awaits the in-flight one, so rapid
    /// filter/page changes can't leave two observers alive.
    private var restartJob: Job? = null

    /// Dedicated search task — deliberately NOT the restart job: typing must
    /// not cancel a pending observer restart (store switch / page change), and
    /// a restart must not await the 500 ms debounce.
    private var searchJob: Job? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    companion object {
        /// Projection shared by the paged observer and search — one row per
        /// order with the joined customer display name. Does NOT project
        /// `o._id`: registerObserver emissions on JOINs namespace `_id` per
        /// collection alias ({o: …, c: …}) which breaks a String decode —
        /// the row derives `_id` from `order_id` (== the order doc's _id).
        const val selectList =
            "o.order_id, o.store_id, o.order_date, o.status, o.subtotal, " +
                "o.total, o.item_count, o.customer_id, c.first_name, c.last_name"

        /// The joined FROM up to and including the store/deleted predicates;
        /// the "Recent only" cutoff is appended when active.
        const val joinedFrom =
            "FROM orders AS o INNER JOIN customers AS c ON o.customer_id = c._id " +
                "WHERE o.store_id = :storeId AND o.deleted = false"

        /// DQL ILIKE (LIKE's case-insensitive variant) on order number and both
        /// customer name fields — the name lives on `customers`, reached
        /// through the join.
        val searchQuery = """
            SELECT $selectList $joinedFrom
            AND (o.order_id ILIKE :like OR c.first_name ILIKE :like OR c.last_name ILIKE :like)
            ORDER BY o.order_date DESC, o._id DESC LIMIT 50
        """.trimIndent()

        const val baseFrom = joinedFrom

        /// Search input cleanup: trim whitespace and drop leading '#' characters —
        /// the list renders order numbers as "#20250115_0001" but the stored id is
        /// "order_20250115_0001". '%' and '_' are left alone: they're ILIKE
        /// wildcards (the info sheet says so), and '_' matches real order ids.
        fun sanitizedSearchTerm(raw: String): String =
            raw.trim().dropWhile { it == '#' }

        /// ISO8601 strings sort lexicographically; the cutoff keeps that property.
        fun cutoffDate(iso: String, days: Int): String? = try {
            val date = Instant.parse(iso)
            Instant.ofEpochMilli(date.minus(days.toLong(), ChronoUnit.DAYS).toEpochMilli()).toString()
        } catch (e: Exception) {
            null
        }
    }

    private data class BuiltQueries(
        val pageQuery: String,
        val countQuery: String,
        val displayQuery: String,
        val arguments: Map<String, Any?>,
    )

    fun restart(appState: AppState) {
        val previous = restartJob
        restartJob = scope.launch {
            previous?.join()
            if (!isActive) return@launch
            restartNow(appState)
        }
    }

    private suspend fun restartNow(appState: AppState) {
        pageObserver?.close()
        countObserver?.close()
        pageObserver = null
        countObserver = null
        val storeId = appState.selectedStoreId.value ?: return

        // Never render the previous store's rows: clear before re-registering
        // so the skeleton shows instead of stale data.
        if (lastStoreId != storeId) {
            orders = emptyList()
            totalCount = 0
        }
        lastStoreId = storeId

        val built = buildQueries(storeId)
        activeQuery = built.displayQuery

        try {
            countObserver = DittoManager.observe<CountRow>(built.countQuery, built.arguments) { rows ->
                totalCount = rows.firstOrNull()?.count ?: 0
                val clamped = Paging.clampPage(page, totalCount, pageSize)
                if (clamped != page) {
                    page = clamped
                    restart(appState)
                }
            }
            pageObserver = DittoManager.observe<OrderSummaryRow>(built.pageQuery, built.arguments) { orders = it }
            error = null
        } catch (e: kotlinx.coroutines.CancellationException) {
            // View torn down mid-restart — not an error state.
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }

    private suspend fun buildQueries(storeId: String): BuiltQueries {
        var fromClause = baseFrom
        val arguments = mutableMapOf<String, Any?>("storeId" to storeId)
        if (recentOnly) {
            val maxDate = latestOrderDate(storeId)
            val cutoff = maxDate?.let { cutoffDate(it, 30) }
            if (maxDate != null && cutoff != null) {
                fromClause += " AND o.order_date > :cutoff"
                arguments["cutoff"] = cutoff
            }
        }

        // Unique tiebreaker: OFFSET paging over a non-unique key can skip or
        // repeat rows across pages.
        val pageQuery = Paging.pageQuery(
            base = "SELECT $selectList $fromClause",
            orderBy = "o.order_date DESC, o._id DESC",
            page = page,
            pageSize = pageSize,
        )
        val countQuery = "SELECT COUNT(*) AS count $fromClause"
        var displayQuery = pageQuery
        for ((key, value) in arguments) {
            displayQuery = displayQuery.replace(":$key", "'$value'")
        }
        return BuiltQueries(pageQuery, countQuery, displayQuery, arguments)
    }

    private suspend fun latestOrderDate(storeId: String): String? {
        val query = """
            SELECT MAX(order_date) AS max_date FROM orders
            WHERE store_id = :storeId AND deleted = false
        """.trimIndent()
        return try {
            DittoManager.fetch<MaxDateRow>(query, mapOf("storeId" to storeId)).firstOrNull()?.max_date
        } catch (e: Exception) {
            null // "recent" shows the full list on failure (Swift logs Logger.ui)
        }
    }

    fun search(appState: AppState) {
        searchJob?.cancel()
        val term = sanitizedSearchTerm(searchText)
        if (term.isEmpty()) {
            searchResults = null
            return
        }
        searchJob = scope.launch {
            delay(500)
            if (!isActive) return@launch
            // Read the store AFTER the debounce: a store switch during the
            // sleep must not fetch the old store's rows into the new context.
            val storeId = appState.selectedStoreId.value ?: return@launch
            try {
                val results = DittoManager.fetch<OrderSummaryRow>(
                    searchQuery,
                    mapOf("storeId" to storeId, "like" to "%$term%"),
                )
                if (!isActive) return@launch
                searchResults = results
                error = null
            } catch (e: kotlinx.coroutines.CancellationException) {
                // cleared/superseded — not an error
            } catch (e: Exception) {
                error = e.localizedMessage
            }
        }
    }

    /// Store switch while a search may be active: drop the old store's matches
    /// immediately (never render another store's data), restart the paged
    /// observers, and re-run the search against the new store.
    fun handleStoreSwitch(appState: AppState) {
        searchResults = null
        page = 1
        restart(appState)
        search(appState)
    }

    fun stop() {
        pageObserver?.close()
        countObserver?.close()
        pageObserver = null
        countObserver = null
        restartJob?.cancel()
        restartJob = null
        searchJob?.cancel()
        searchJob = null
    }
}

@Composable
fun OrdersScreen(appState: AppState, onOpenOrder: (OrderSummaryRow) -> Unit, modifier: Modifier = Modifier) {
    val state = remember { OrdersState() }
    val selectedStoreId by appState.selectedStoreId.collectAsStateWithLifecycle()
    val colors = DittoColors.current

    LaunchedEffect(Unit) { state.restart(appState) }
    DisposableEffect(Unit) { onDispose { state.stop() } }
    // Mirrors SwiftUI's onChange: fires only when the selection CHANGES while
    // this screen is alive, not on first composition.
    val initialStoreId = remember { selectedStoreId }
    LaunchedEffect(selectedStoreId) {
        if (selectedStoreId != initialStoreId) state.handleStoreSwitch(appState)
    }

    // The query actually driving the list right now: the ILIKE one-shot with
    // args resolved inline while searching, else the live paged observer query.
    val displayedQuery = if (state.isSearching && selectedStoreId != null) {
        val term = OrdersState.sanitizedSearchTerm(state.searchText)
        OrdersState.searchQuery
            .replace(":storeId", "'$selectedStoreId'")
            .replace(":like", "'%$term%'")
    } else {
        state.activeQuery.ifEmpty {
            "SELECT ${OrdersState.selectList} ${OrdersState.baseFrom} ORDER BY o.order_date DESC"
        }
    }

    // The app bar carries this screen's info action (the in-row button didn't
    // fit beside the toggle on narrow screens).
    PublishScreenInfo(displayedQuery, ordersScreenExplanation)

    Column(modifier = modifier) {
        // Search is the standard field with the × clear affordance (parity
        // with the iOS .searchable control); debounced ILIKE in the state.
        ZavaSearchField(
            value = state.searchText,
            onValueChange = {
                state.searchText = it
                state.search(appState)
            },
            placeholder = "Search order # or customer…",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        Row(
            modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            // M3 list-item spacing: 16dp between label text and the control.
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "Recent only (last 30 days of data)",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.foregroundNormal,
            )
            Switch(
                checked = state.recentOnly,
                onCheckedChange = {
                    state.recentOnly = it
                    state.page = 1
                    state.restart(appState)
                },
            )
            Spacer(Modifier.weight(1f))
        }
        HorizontalDivider()

        Box(modifier = Modifier.weight(1f)) {
            if (state.visibleOrders.isEmpty()) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    state.error?.let { DittoBadge(it, DittoBadgeStatus.Critical) }
                        ?: if (state.isSearching) {
                            Text("No matches", color = colors.foregroundSubtle)
                        } else {
                            SkeletonRows(count = 8)
                        }
                }
            } else {
                LazyColumn {
                    items(state.visibleOrders, key = { it.id }) { order ->
                        OrderRow(order, onClick = { onOpenOrder(order) })
                        HorizontalDivider(thickness = 0.5.dp, color = colors.borderNormal)
                    }
                }
            }
        }

        HorizontalDivider()
        if (state.isSearching) {
            // Same height as the pagination bar so the list doesn't jump;
            // discloses the LIMIT 50 cap.
            Row(
                modifier = Modifier.fillMaxWidth().height(60.dp).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (state.visibleOrders.size >= 50) {
                        "First 50 matches shown (cap) — refine the term, or clear search for the paged list"
                    } else {
                        "${state.visibleOrders.size} ${if (state.visibleOrders.size == 1) "match" else "matches"} — clear search for the paged list"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.foregroundSubtle,
                )
            }
        } else {
            PaginationBar(
                totalCount = state.totalCount,
                page = state.page,
                pageSize = state.pageSize,
                pageSizes = listOf(25, 50, 100, 250),
                onPage = { state.page = it; state.restart(appState) },
                onPageSize = { state.pageSize = it; state.restart(appState) },
            )
        }
    }
}

@kotlinx.serialization.Serializable
private data class MaxDateRow(val max_date: String? = null)

private const val ordersScreenExplanation =
    "The orders list is a LIVE observer over this store's orders INNER JOINed to customers — the normalized schema carries customer ids only, so the name on each row comes from the join (Ditto SDK 5.1, on-device). New matches appear as sync delivers them, no refresh step. The query shown above is the exact one running (cutoff/args resolved).\n\nPagination is LIMIT/OFFSET in DQL over the join: the visible slice runs ORDER BY o.order_date DESC, o._id DESC LIMIT <pageSize> OFFSET <(page−1)×pageSize>, while a second live observer runs COUNT(*) over the same joined FROM — so the page count climbs as sync delivers. The o._id tiebreaker keeps OFFSET paging stable (no skipped or repeated rows across pages).\n\n\"Recent only\" anchors to max(order_date) IN THE DATA (the benchmark dataset ends 2025-06-27), not the device clock — a naive now-minus-30-days filter would show zero rows. Search runs one-shot case-insensitive ILIKE queries on order number and the JOINED customer's first/last name (500 ms debounce, capped at 50 rows) — '%' and '_' in your input act as wildcards, and search matches across all dates (it ignores the \"Recent only\" filter); clear it (×) to return to the live paged list."

@Composable
private fun OrderRow(order: OrderSummaryRow, onClick: () -> Unit) {
    val colors = DittoColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                order.order_id.replace("order_", "#"),
                style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
                color = colors.foregroundNormal,
            )
            Text(
                "${order.customerName} · ${Formatters.dateTime(order.order_date)}",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.foregroundSubtle,
            )
        }
        Spacer(Modifier.weight(1f))
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                Formatters.usd(order.total),
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                color = colors.foregroundNormal,
            )
            Text(
                "${order.item_count} item${if (order.item_count == 1) "" else "s"}",
                style = MaterialTheme.typography.bodySmall,
                color = colors.foregroundSubtle,
            )
        }
    }
}

/// Order detail = the order row (already joined to its customer by the list)
/// plus its line items through a second INNER JOIN (order_items ⨝ products) —
/// product names/SKUs live only on the products collection in the normalized
/// schema. Ditto SDK 5.1 runs both joins on-device; sync subscriptions still
/// can't JOIN, which is why items sync chain-wide.
@Composable
fun OrderDetailScreen(order: OrderSummaryRow, appState: AppState, modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    var items by remember { mutableStateOf<List<OrderLineRow>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }

    // The store display name lives on the synced `stores` catalog (shared),
    // not on the order document — look it up instead of joining.
    val stores by appState.stores.collectAsStateWithLifecycle()
    val storeName = stores.firstOrNull { it.store_id == order.store_id }?.store_name ?: order.store_id

    PublishScreenInfo(OrderDetailQueries.itemsQuery, OrderDetailQueries.explanation)

    LaunchedEffect(order.id) {
        try {
            items = DittoManager.fetch<OrderLineRow>(
                OrderDetailQueries.itemsQuery,
                mapOf("orderId" to order.order_id),
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            // View torn down mid-fetch — not an error state.
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }

    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        DittoCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    order.order_id,
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
                    color = colors.foregroundNormal,
                )
                Text(order.customerName, style = MaterialTheme.typography.titleLarge, color = colors.foregroundNormal)
                Text(
                    "${Formatters.dateTime(order.order_date)} · $storeName",
                    color = colors.foregroundSubtle,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    DittoBadge(order.status, DittoBadgeStatus.Success)
                    Spacer(Modifier.weight(1f))
                    Text(
                        Formatters.usd(order.total),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.foregroundNormal,
                    )
                }
            }
        }

        DittoCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Line items", OrderDetailQueries.itemsQuery, OrderDetailQueries.explanation)
                items.forEach { item ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(item.product_name ?: item.product_id, color = colors.foregroundNormal)
                            Text(
                                item.sku ?: "—",
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                                color = colors.foregroundSubtle,
                            )
                        }
                        Text("×${item.quantity}", color = colors.foregroundSubtle)
                        Spacer(Modifier.width(12.dp))
                        Text(
                            Formatters.usd(item.line_total),
                            style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
                            color = colors.foregroundNormal,
                            modifier = Modifier.width(90.dp),
                            textAlign = androidx.compose.ui.text.style.TextAlign.End,
                        )
                    }
                }
                if (items.isEmpty()) {
                    androidx.compose.material3.CircularProgressIndicator()
                }
                error?.let { DittoBadge(it, DittoBadgeStatus.Critical) }
            }
        }
    }
}

private object OrderDetailQueries {
    const val itemsQuery =
        "SELECT oi._id, oi.order_id, oi.product_id, oi.quantity, oi.unit_price, " +
            "oi.discount_percent, oi.discount_amount, oi.line_total, p.product_name, p.sku " +
            "FROM order_items AS oi INNER JOIN products AS p ON oi.product_id = p._id " +
            "WHERE oi.order_id = :orderId AND oi.deleted = false"
    const val explanation =
        "One INNER JOIN per hop: the list joined orders ⨝ customers for the name on this card, and this screen joins order_items ⨝ products for the item names and SKUs. The normalized dataset carries ids only (no embedded customer_name / product_name copies) — Ditto SDK 5.1 resolves them on-device. This is the benchmark's items__join__products shape with a parameterized order id."
}
