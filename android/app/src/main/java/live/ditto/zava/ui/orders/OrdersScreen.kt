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
import live.ditto.zava.model.Order
import live.ditto.zava.model.OrderItem
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

/// The orders list is a live, PAGED store observer (PLAN §4.2.2): the page
/// slice is `ORDER BY order_date DESC LIMIT pageSize OFFSET (page-1)*pageSize`
/// and the total comes from a COUNT observer — both live-update as sync runs.
/// The "recent" filter anchors to max(order_date) in the local store — the
/// dataset ends 2025-06-27, so a device-clock-relative filter would show
/// zero rows.
class OrdersState {
    var orders by mutableStateOf<List<Order>>(emptyList())
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
    var searchResults by mutableStateOf<List<Order>?>(null)
    val isSearching: Boolean get() = searchResults != null
    val visibleOrders: List<Order> get() = searchResults ?: orders

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
        /// DQL ILIKE (LIKE's case-insensitive variant) on both order number and
        /// customer name.
        const val searchQuery = """
            SELECT * FROM orders WHERE store_id = :storeId AND deleted = false
            AND (order_id ILIKE :like OR customer_name ILIKE :like)
            ORDER BY order_date DESC, _id DESC LIMIT 50
        """

        const val baseWhere = "FROM orders WHERE store_id = :storeId AND deleted = false"

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
            pageObserver = DittoManager.observe<Order>(built.pageQuery, built.arguments) { orders = it }
            error = null
        } catch (e: kotlinx.coroutines.CancellationException) {
            // View torn down mid-restart — not an error state.
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }

    private suspend fun buildQueries(storeId: String): BuiltQueries {
        var whereClause = baseWhere
        val arguments = mutableMapOf<String, Any?>("storeId" to storeId)
        if (recentOnly) {
            val maxDate = latestOrderDate(storeId)
            val cutoff = maxDate?.let { cutoffDate(it, 30) }
            if (maxDate != null && cutoff != null) {
                whereClause += " AND order_date > :cutoff"
                arguments["cutoff"] = cutoff
            }
        }

        // Unique tiebreaker: OFFSET paging over a non-unique key can skip or
        // repeat rows across pages.
        val pageQuery = Paging.pageQuery(
            base = "SELECT * $whereClause",
            orderBy = "order_date DESC, _id DESC",
            page = page,
            pageSize = pageSize,
        )
        val countQuery = "SELECT COUNT(*) AS count $whereClause"
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
                val results = DittoManager.fetch<Order>(
                    searchQuery.trimIndent(),
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
fun OrdersScreen(appState: AppState, onOpenOrder: (Order) -> Unit, modifier: Modifier = Modifier) {
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
        OrdersState.searchQuery.trimIndent()
            .replace(":storeId", "'$selectedStoreId'")
            .replace(":like", "'%$term%'")
    } else {
        state.activeQuery.ifEmpty {
            "SELECT * ${OrdersState.baseWhere} ORDER BY order_date DESC"
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
    "The orders list is a LIVE observer over this store's synced orders — new matches appear as sync delivers them, no refresh step. The query shown above is the exact one running (cutoff/args resolved).\n\nPagination is LIMIT/OFFSET in DQL: the visible slice runs ORDER BY order_date DESC, _id DESC LIMIT <pageSize> OFFSET <(page−1)×pageSize>, while a second live observer runs COUNT(*) over the same WHERE — so the page count climbs as sync delivers. The _id tiebreaker keeps OFFSET paging stable (no skipped or repeated rows across pages).\n\n\"Recent only\" anchors to max(order_date) IN THE DATA (the benchmark dataset ends 2025-06-27), not the device clock — a naive now-minus-30-days filter would show zero rows. Search runs one-shot case-insensitive ILIKE queries on order number and customer name (500 ms debounce, capped at 50 rows); clear it (×) to return to the live paged list."

@Composable
private fun OrderRow(order: Order, onClick: () -> Unit) {
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
                "${order.customer_name} · ${Formatters.dateTime(order.order_date)}",
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

/// Order detail = order + its items via the canonical two-query pattern.
/// DQL v5.0 has no JOINs: the first query fetched the order (the list's
/// observer), this screen runs the second (items by order_id).
@Composable
fun OrderDetailScreen(order: Order, modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    var items by remember { mutableStateOf<List<OrderItem>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }

    PublishScreenInfo(OrderDetailQueries.itemsQuery, OrderDetailQueries.explanation)

    LaunchedEffect(order.id) {
        try {
            items = DittoManager.fetch<OrderItem>(
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
                Text(order.customer_name, style = MaterialTheme.typography.titleLarge, color = colors.foregroundNormal)
                Text(
                    "${Formatters.dateTime(order.order_date)} · ${order.store_name}",
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
                            Text(item.product_name, color = colors.foregroundNormal)
                            Text(
                                item.sku,
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
    const val itemsQuery = "SELECT * FROM order_items WHERE order_id = :orderId AND deleted = false"
    const val explanation = "DQL v5.0 has no JOINs, so order detail is two queries: the list's live observer fetched this order, and this screen ran the second query — order_items filtered by order_id. That's the canonical DQL pattern the benchmark measures as the orders__select__by_id + order_items__select__by_order pair."
}
