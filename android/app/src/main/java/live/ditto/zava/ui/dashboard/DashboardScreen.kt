package live.ditto.zava.ui.dashboard

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import live.ditto.anvil.material3.DittoColors
import live.ditto.anvil.material3.DittoMonoFontFamily
import live.ditto.zava.R
import live.ditto.zava.data.DittoManager
import live.ditto.zava.model.CountRow
import live.ditto.zava.model.InventoryItem
import live.ditto.zava.model.MonthTrendRow
import live.ditto.zava.model.Product
import live.ditto.zava.model.StatusRevenueRow
import live.ditto.zava.model.Store
import live.ditto.zava.model.TopProductRow
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.Formatters
import live.ditto.zava.ui.components.DittoBadge
import live.ditto.zava.ui.components.DittoBadgeStatus
import live.ditto.zava.ui.components.DittoCard
import live.ditto.zava.ui.components.PublishScreenInfo
import live.ditto.zava.ui.components.QueryInfoButton
import live.ditto.zava.ui.components.SectionHeader
import live.ditto.zava.ui.components.SkeletonCard
import live.ditto.zava.ui.components.SkeletonRows
import live.ditto.zava.ui.formatted
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/// Dashboard KPI queries — derived from the retail-joins benchmark catalog's
/// aggregation entries (joins__agg__*, inventory__select__low_stock_* shapes).
/// Aliases are added so rows decode into typed models; the exact string that
/// executes is always shown in the card's info sheet.
object DashboardQueries {
    const val statusRevenue = """
        SELECT status, COUNT(*) AS orders, SUM(total) AS revenue
        FROM orders WHERE store_id = :storeId AND deleted = false GROUP BY status
    """
    const val monthlyTrend = """
        SELECT substr(order_date, 0, 7) AS month, COUNT(*) AS orders, SUM(total) AS revenue
        FROM orders WHERE store_id = :storeId AND deleted = false
        GROUP BY substr(order_date, 0, 7) ORDER BY substr(order_date, 0, 7) DESC LIMIT 12
    """
    /// Benchmark-shaped (inventory__select__low_stock): the store predicate
    /// keeps the KPI correct even if a store switch left stale inventory
    /// behind (don't rely on the eviction invariant alone).
    const val lowStock = """
        SELECT COUNT(*) AS count FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false
    """
    /// The rows behind the count — the card lists the most critical SKUs.
    const val lowStockItems = """
        SELECT * FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false
        ORDER BY stock_level LIMIT 5
    """
    /// The full customer directory is an unfiltered subscription — this count
    /// is the shared directory every device holds (50K docs).
    const val customersCount = "SELECT COUNT(*) AS count FROM customers WHERE deleted = false"
    /// The shared catalog (424 products, unfiltered subscription).
    const val productsCount = "SELECT COUNT(*) AS count FROM products WHERE deleted = false"

    /// Top products by revenue for the selected store. order_items carries a
    /// store_id denormalized from the parent order, but the store filter still
    /// rides the INNER JOIN — the suite's canonical "items via orders" shape
    /// (a direct oi.store_id = :storeId filter would also work; that's what
    /// the item subscription uses). LIMIT comes from the card's pull-down
    /// (5/10/25/50/100).
    /// DQL GROUP BY projects only group keys + aggregates, so product names
    /// resolve client-side against the synced catalog.
    fun topProducts(limit: Int) = """
        SELECT oi.product_id, SUM(oi.line_total) AS revenue
        FROM order_items AS oi INNER JOIN orders AS o ON oi.order_id = o._id
        WHERE o.store_id = :storeId AND o.deleted = false AND oi.deleted = false
        GROUP BY oi.product_id ORDER BY revenue DESC LIMIT $limit
    """

    /// The whole catalog is small (424 docs) — observed live so aggregate rows
    /// (product_id only) can display product names.
    const val productsCatalog = "SELECT * FROM products WHERE deleted = false"
}

/// The dashboard is LIVE: every card is a store observer, not a one-shot
/// fetch — after a store switch the cards climb as the new store's data syncs
/// (the demo's headline moment), with no manual refresh and no stale data
/// (a store change clears the snapshot first; ghost cards show meanwhile).
class DashboardState {
    var statusRows by mutableStateOf<List<StatusRevenueRow>>(emptyList())
    var monthRows by mutableStateOf<List<MonthTrendRow>>(emptyList())
    var lowStockCount by mutableStateOf<Int?>(null)
    var lowStockItems by mutableStateOf<List<InventoryItem>>(emptyList())
    var topProducts by mutableStateOf<List<TopProductRow>>(emptyList())
    var topProductsLimit by mutableStateOf(5)
    var customersCount by mutableStateOf<Int?>(null)
    var productsCount by mutableStateOf<Int?>(null)
    var productNames by mutableStateOf<Map<String, String>>(emptyMap())
    var error by mutableStateOf<String?>(null)

    private var observers = mutableListOf<com.ditto.kotlin.DittoStoreObserver>()
    private var topProductsObserver: com.ditto.kotlin.DittoStoreObserver? = null

    /// MUST be observable state: Compose tracks reads, and the stale branch of
    /// the KPI grid reads none of the value fields — a plain var here leaves
    /// the skeletons up forever (caught on-device: grid never recomposed).
    private var loadedFor by mutableStateOf<String?>(null)
    private var restartJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun productName(productId: String): String = productNames[productId] ?: productId

    /// True while the visible snapshot belongs to a different store than the
    /// selection (initial load + the window after a switch).
    fun isStale(selectedStoreId: String?): Boolean = loadedFor != selectedStoreId

    /// After a store switch, wipe the previous store's snapshot so nothing
    /// stale renders while the new store syncs (ghost cards show instead).
    fun clearForStoreChange() {
        statusRows = emptyList()
        monthRows = emptyList()
        lowStockCount = null
        lowStockItems = emptyList()
        topProducts = emptyList()
        customersCount = null
        productsCount = null
        loadedFor = null
    }

    /// Start all card observers (serialized against in-flight restarts).
    fun start(appState: AppState) {
        val previous = restartJob
        restartJob = scope.launch {
            previous?.join()
            if (!isActive) return@launch
            startObservers(appState)
        }
    }

    /// Observer-only teardown — startObservers calls this (stop() would
    /// cancel the very coroutine startObservers is running on).
    private fun cancelObservers() {
        observers.forEach { it.close() }
        observers.clear()
        topProductsObserver?.close()
        topProductsObserver = null
    }

    fun stop() {
        cancelObservers()
        restartJob?.cancel()
        restartJob = null
        loadedFor = null
    }

    /// The Top-N pull-down re-registers just the top-products observer.
    fun setTopProductsLimit(limit: Int, appState: AppState) {
        topProductsLimit = limit
        val storeId = appState.selectedStoreId.value ?: return
        topProductsObserver?.close()
        topProductsObserver = try {
            DittoManager.observe<TopProductRow>(
                DashboardQueries.topProducts(limit).trimIndent(),
                mapOf("storeId" to storeId),
            ) { rows -> topProducts = rows.filter { it.product_id != null } }
        } catch (e: Exception) {
            error = e.localizedMessage
            null
        }
    }

    private fun startObservers(appState: AppState) {
        cancelObservers() // NOT stop() — that would cancel our own coroutine
        val storeId = appState.selectedStoreId.value ?: return
        // Register one at a time INTO the tracked list: if any registration
        // throws, the earlier observers stay tracked (stop() can close them)
        // instead of leaking as anonymous live observers (adversarial review:
        // batch `+= listOf(...)` dropped partial registrations untracked).
        try {
            observers += DittoManager.observe<StatusRevenueRow>(
                DashboardQueries.statusRevenue.trimIndent(), mapOf("storeId" to storeId),
            ) { rows ->
                statusRows = rows.filter { it.status != null }.sortedByDescending { it.orders }
            }
            observers += DittoManager.observe<MonthTrendRow>(
                DashboardQueries.monthlyTrend.trimIndent(), mapOf("storeId" to storeId),
            ) { rows -> monthRows = rows.filter { it.month != null } }
            observers += DittoManager.observe<CountRow>(
                DashboardQueries.lowStock.trimIndent(), mapOf("storeId" to storeId),
            ) { rows -> lowStockCount = rows.firstOrNull()?.count ?: 0 }
            observers += DittoManager.observe<InventoryItem>(
                DashboardQueries.lowStockItems.trimIndent(), mapOf("storeId" to storeId),
            ) { rows -> lowStockItems = rows }
            // Shared-catalog observers (no store arg).
            observers += DittoManager.observe<CountRow>(DashboardQueries.customersCount) { rows ->
                customersCount = rows.firstOrNull()?.count ?: 0
            }
            observers += DittoManager.observe<CountRow>(DashboardQueries.productsCount) { rows ->
                productsCount = rows.firstOrNull()?.count ?: 0
            }
            observers += DittoManager.observe<Product>(DashboardQueries.productsCatalog) { products ->
                productNames = products.associate { it.product_id to it.product_name }
            }
            topProductsObserver = DittoManager.observe<TopProductRow>(
                DashboardQueries.topProducts(topProductsLimit).trimIndent(), mapOf("storeId" to storeId),
            ) { rows -> topProducts = rows.filter { it.product_id != null } }
            loadedFor = storeId
            error = null
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }
}

private const val dashboardScreenExplanation =
    "Every card is a LIVE store observer, not a one-shot fetch — after a store switch the values climb as the new store syncs, and ghost cards cover the gap so you never see another store's rows. The KPI cards aggregate orders by status (COUNT + SUM, above with your store substituted); the trend groups orders into months with substr(order_date, 0, 7) (DQL's substr is zero-based); low stock rides the composite _id.store_id subfield; top products sums line totals per product with the store filter applied through an INNER JOIN to the parent order (items do carry a denormalized store_id — the JOIN demonstrates the suite's canonical shape; the item subscription filters on the item's own field). Each card's own ⓘ shows the exact query behind it."

private object Explanations {
    const val statusRevenue = "Counts this store's non-deleted orders and sums their totals, grouped by status. It's the benchmark's by-status aggregation scoped to your store — the same DQL shape the performance suite measures."
    const val customersCount = "Counts the customer documents synced to this device. The app subscribes to ALL customers unfiltered — a walk-in could be anyone, so the whole 50K-row directory lives on device."
    const val productsCount = "Counts the shared product catalog synced to this device (424 docs). The catalog is subscribed unfiltered: a rep can sell anything, from any store."
    const val monthlyTrend = "Groups this store's orders into calendar months with substr(order_date, 0, 7) (DQL's substr is zero-based — a classic gotcha) and shows the latest 12. One of the heavier aggregation queries in the benchmark."
    const val lowStock = "Counts and lists inventory rows at your store with fewer than 5 units left. The store filter rides the composite _id subfield (_id.store_id) — the benchmark's index-backed \"low stock alert\" query."
    const val topProducts = "Sums line totals per product across this store's order items and takes the top N by revenue (the pull-down sets N). Items carry store_id denormalized from the parent order (subscriptions can't JOIN — that's how item sync stays per-store); this card still filters through the INNER JOIN to demonstrate the suite's canonical \"items via orders\" shape. The GROUP BY projects product_id only, so names resolve against the synced catalog. This card is a live observer: values climb as sync delivers the store."
}

@Composable
fun DashboardScreen(appState: AppState, modifier: Modifier = Modifier) {
    val state = remember { DashboardState() }
    val selectedStoreId by appState.selectedStoreId.collectAsStateWithLifecycle()
    val stores by appState.stores.collectAsStateWithLifecycle()

    DisposableEffect(selectedStoreId) {
        state.clearForStoreChange()
        state.start(appState)
        onDispose { state.stop() }
    }

    // The app bar carries this screen's info action; the headline KPI query
    // with the selected store substituted (each card's own ⓘ shows its query).
    val infoQuery = DashboardQueries.statusRevenue.trimIndent()
        .replace(":storeId", "'${selectedStoreId ?: "store_seattle"}'")
    PublishScreenInfo(infoQuery, dashboardScreenExplanation)

    val colors = DittoColors.current
    val store = stores.firstOrNull { it.store_id == selectedStoreId }

    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        DashboardHeader(store = store, stores = stores, selectedStoreId = selectedStoreId, appState = appState)
        state.error?.let { DittoBadge(it, DittoBadgeStatus.Critical) }

        KpiGrid(state = state, stale = state.isStale(selectedStoreId))
        TrendCard(state = state, stale = state.isStale(selectedStoreId))
        LowStockCard(state = state, stale = state.isStale(selectedStoreId))
        TopProductsCard(state = state, stale = state.isStale(selectedStoreId), appState = appState)
    }
}

/// One line: store name (tap to switch stores in place — no trip to the
/// Ditto tab) · location. The store picker is the showcase flow; this menu
/// is the fast path.
@Composable
private fun DashboardHeader(
    store: Store?,
    stores: List<Store>,
    selectedStoreId: String?,
    appState: AppState,
) {
    val colors = DittoColors.current
    var menuOpen by remember { mutableStateOf(false) }
    BoxWithConstraints {
        // Below ~400dp (folded cover) the location would squeeze to an
        // unreadable sliver next to the logo — drop it, keep store + logo.
        val showLocation = maxWidth > 400.dp
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box {
                TextButton(onClick = { menuOpen = true }, modifier = Modifier.testTag("storeSwitcher")) {
                    Text(
                        store?.store_name ?: selectedStoreId ?: "—",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.foregroundNormal,
                    )
                    Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = colors.foregroundSubtle)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    stores.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.store_name) },
                            trailingIcon = {
                                if (option.store_id == selectedStoreId) {
                                    Icon(Icons.Filled.Check, contentDescription = null)
                                }
                            },
                            onClick = {
                                menuOpen = false
                                if (option.store_id != selectedStoreId) appState.selectStore(option.store_id)
                            },
                        )
                    }
                }
            }
            if (store != null && showLocation) {
                val location = if (store.location.address == "n/a") {
                    "${store.location.city}, ${store.location.state}"
                } else {
                    "${store.location.address}, ${store.location.city}, ${store.location.state}"
                }
                Text(
                    "· $location",
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.foregroundSubtle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
            }
            Spacer(Modifier.weight(1f))
            // The full Ditto logotype, trailing on the same line as the store
            // switcher (tinted with the Anvil foreground token — adapts to
            // dark/light like the SVG variants).
            androidx.compose.foundation.Image(
                painter = painterResource(R.drawable.ditto_logotype),
                contentDescription = "Ditto",
                modifier = Modifier.height(22.dp),
                alignment = Alignment.CenterStart,
                colorFilter = ColorFilter.tint(colors.foregroundNormal),
            )
        }
    }
}

/// Centered, width-capped KPI grid: 4-up on wide layouts, 2×2 below 900dp,
/// ONE card per row below 500dp (Compose has no minimumScaleFactor — at
/// ~160dp card width on folded-cover-size screens the revenue value would
/// ellipsize, so narrow screens stack). Ghost cards while the snapshot
/// belongs to another store.
@Composable
private fun KpiGrid(state: DashboardState, stale: Boolean) {
    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val columnCount = when {
            maxWidth < 500.dp -> 1
            maxWidth < 900.dp -> 2
            else -> 4
        }
        val cells: List<@Composable (Modifier) -> Unit> = if (stale) {
            List(4) { { m -> SkeletonCard(m) } }
        } else {
            listOf(
                { m -> KpiCard(m, "Orders", state.statusRows.sumOf { it.orders }.formatted(), DashboardQueries.statusRevenue.trimIndent(), Explanations.statusRevenue, "kpi.orders") },
                { m -> KpiCard(m, "Revenue (all time)", Formatters.usd(state.statusRows.sumOf { it.revenue ?: 0.0 }), DashboardQueries.statusRevenue.trimIndent(), Explanations.statusRevenue, "kpi.revenue") },
                { m -> KpiCard(m, "Customers synced", state.customersCount?.formatted() ?: "…", DashboardQueries.customersCount, Explanations.customersCount, "kpi.customers") },
                { m -> KpiCard(m, "Catalog products", state.productsCount?.formatted() ?: "…", DashboardQueries.productsCount, Explanations.productsCount, "kpi.products") },
            )
        }
        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Column(
                modifier = Modifier.widthIn(max = 1400.dp).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                cells.chunked(columnCount).forEach { rowCells ->
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        rowCells.forEach { cell -> cell(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun KpiCard(
    modifier: Modifier,
    title: String,
    value: String,
    query: String,
    explanation: String,
    testTag: String,
) {
    val colors = DittoColors.current
    DittoCard(modifier = modifier) {
        Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.bodyMedium, color = colors.foregroundSubtle)
                Spacer(Modifier.weight(1f))
                QueryInfoButton(query = query, explanation = explanation)
            }
            // KPI values must never wrap — shrink instead (maxLines + ellipsis
            // keep "$19,513,528.40" on one line).
            Text(
                value,
                style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.SemiBold),
                color = colors.foregroundNormal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.testTag(testTag),
            )
        }
    }
}

@Composable
private fun TrendCard(state: DashboardState, stale: Boolean) {
    val colors = DittoColors.current
    DittoCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SectionHeader("Monthly trend", DashboardQueries.monthlyTrend.trimIndent(), Explanations.monthlyTrend)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Month", modifier = Modifier.width(64.dp), style = headerStyle())
                Spacer(Modifier.weight(1f))
                Text("Orders", modifier = Modifier.width(70.dp), style = headerStyle(), textAlign = TextAlign.End)
                Text("Revenue", modifier = Modifier.width(110.dp), style = headerStyle(), textAlign = TextAlign.End)
            }
            if (stale) {
                SkeletonRows(count = 5)
            } else {
                val maxOrders = maxOf(1, state.monthRows.maxOfOrNull { it.orders } ?: 1)
                state.monthRows.forEach { row ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(row.month ?: "—", modifier = Modifier.width(64.dp), style = cellStyle())
                        // Revenue bar scaled to the busiest month.
                        Box(modifier = Modifier.weight(1f).height(14.dp)) {
                            Surface(
                                modifier = Modifier
                                    .fillMaxHeight()
                                    .fillMaxWidth(row.orders.toFloat() / maxOrders),
                                color = colors.fillBrandPrimary,
                                shape = RoundedCornerShape(3.dp),
                            ) {}
                        }
                        Text(row.orders.formatted(), modifier = Modifier.width(70.dp), style = cellStyle(), textAlign = TextAlign.End)
                        Text(Formatters.usd(row.revenue ?: 0.0), modifier = Modifier.width(110.dp), style = cellStyle(subtle = true), textAlign = TextAlign.End)
                    }
                }
                if (state.monthRows.isEmpty()) {
                    Text("No orders synced yet for this store.", color = colors.foregroundSubtle)
                }
            }
        }
    }
}

@Composable
private fun LowStockCard(state: DashboardState, stale: Boolean) {
    val colors = DittoColors.current
    DittoCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SectionHeader("Low stock", DashboardQueries.lowStock.trimIndent(), Explanations.lowStock) {
                if (!stale) {
                    state.lowStockCount?.let { count ->
                        DittoBadge(
                            if (count == 0) "No low stock found" else "$count SKU${if (count == 1) "" else "s"} under 5 units",
                            if (count > 0) DittoBadgeStatus.Warning else DittoBadgeStatus.Success,
                            modifier = Modifier.testTag("lowStock.badge"),
                        )
                    }
                }
            }
            if (stale) {
                SkeletonRows(count = 4)
            } else {
                state.lowStockCount?.let { count ->
                    if (count == 0) {
                        Text(
                            "Everything at this store has 5+ units on hand.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = colors.foregroundSubtle,
                        )
                    } else {
                        state.lowStockItems.forEach { item ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    state.productName(item.product_id),
                                    color = colors.foregroundNormal,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    "Aisle ${item.location.aisle}",
                                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                                    color = colors.foregroundSubtle,
                                )
                                Spacer(Modifier.width(8.dp))
                                DittoBadge(
                                    if (item.stock_level == 0) "out" else "${item.stock_level} left",
                                    if (item.stock_level == 0) DittoBadgeStatus.Critical else DittoBadgeStatus.Warning,
                                )
                            }
                        }
                        if (count > state.lowStockItems.size) {
                            Text(
                                "+ ${count - state.lowStockItems.size} more — full list in Products → ⚠ Low stock",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.foregroundSubtle,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TopProductsCard(state: DashboardState, stale: Boolean, appState: AppState) {
    val colors = DittoColors.current
    var menuOpen by remember { mutableStateOf(false) }
    DittoCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SectionHeader(
                "Top products by revenue",
                DashboardQueries.topProducts(state.topProductsLimit).trimIndent(),
                Explanations.topProducts,
            ) {
                Box {
                    TextButton(onClick = { menuOpen = true }, modifier = Modifier.testTag("topProducts.limit")) {
                        Text("Top ${state.topProductsLimit}", color = colors.foregroundSubtle)
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        listOf(5, 10, 25, 50, 100).forEach { limit ->
                            DropdownMenuItem(
                                text = { Text("$limit") },
                                onClick = {
                                    menuOpen = false
                                    state.setTopProductsLimit(limit, appState)
                                },
                            )
                        }
                    }
                }
            }
            if (stale) {
                SkeletonRows(count = 5)
            } else {
                state.topProducts.forEachIndexed { rank, row ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${rank + 1}.",
                            modifier = Modifier.width(28.dp),
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                            color = colors.foregroundSubtle,
                        )
                        Text(
                            state.productName(row.product_id ?: ""),
                            color = colors.foregroundNormal,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            Formatters.usd(row.revenue ?: 0.0),
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                            color = colors.foregroundSubtle,
                        )
                    }
                }
                if (state.topProducts.isEmpty()) {
                    Text("No sales yet for this store.", color = colors.foregroundSubtle)
                }
            }
        }
    }
}

@Composable
private fun headerStyle() =
    MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily, color = DittoColors.current.foregroundSubtle)

@Composable
private fun cellStyle(subtle: Boolean = false) =
    MaterialTheme.typography.bodySmall.copy(
        fontFamily = DittoMonoFontFamily,
        color = if (subtle) DittoColors.current.foregroundSubtle else DittoColors.current.foregroundNormal,
    )
