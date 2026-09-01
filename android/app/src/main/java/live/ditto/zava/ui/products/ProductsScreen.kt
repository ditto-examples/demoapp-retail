package live.ditto.zava.ui.products

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
import live.ditto.zava.model.Category
import live.ditto.zava.model.CountRow
import live.ditto.zava.model.InventoryItem
import live.ditto.zava.model.Paging
import live.ditto.zava.model.Product
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

/// Products catalog: paged live observers over the shared catalog (400 docs),
/// joined in-memory with this store's inventory (per-store subscription) for
/// stock badges. Low-stock mode pages the inventory collection directly. The
/// composite-_id teaching moment lives in the detail view's location lookup.
class ProductsState {
    /// A row is a product plus (when stocked at this store) its inventory.
    data class Row(val product: Product, val stock: InventoryItem?) {
        val id: String get() = product.id
    }

    var categories by mutableStateOf<List<Category>>(emptyList())
    var rows by mutableStateOf<List<Row>>(emptyList())
    var totalCount by mutableStateOf(0)
    var page by mutableStateOf(1)
    var pageSize by mutableStateOf(25)
    var selectedCategoryId by mutableStateOf<String?>(null)
    var searchText by mutableStateOf("")
    var searchResults by mutableStateOf<List<Product>?>(null)
    var lowStockOnly by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    /// The exact paged query currently observed (args resolved inline) — the
    /// app bar's info sheet shows this, not a template.
    var activeQuery by mutableStateOf("")

    val isSearching: Boolean get() = searchResults != null

    private var categoriesObserver: DittoStoreObserver? = null
    private var productsAllObserver: DittoStoreObserver? = null
    private var inventoryAllObserver: DittoStoreObserver? = null
    private var pageObserver: DittoStoreObserver? = null
    private var countObserver: DittoStoreObserver? = null
    private var restartJob: Job? = null
    private var searchJob: Job? = null
    private var productsById: Map<String, Product> = emptyMap()
    private var stockByProduct: Map<String, InventoryItem> = emptyMap()
    private var startedFor: String? = null
    private var lastStoreId: String? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    companion object {
        const val productsWhere = "FROM products WHERE deleted = false"
        const val productsByCategoryWhere = "FROM products WHERE category_id = :categoryId AND deleted = false"
        const val lowStockWhere = "FROM inventory WHERE stock_level < 5 AND deleted = false"
        const val searchQuery = """
            SELECT * FROM products WHERE deleted = false
            AND (sku = :term OR product_name LIKE :like) ORDER BY product_name LIMIT 50
        """
    }

    val visibleRows: List<Row>
        get() = searchResults?.map { Row(it, stockByProduct[it.product_id]) } ?: rows

    fun start(appState: AppState) {
        if (startedFor != null) return
        startedFor = appState.selectedStoreId.value
        try {
            categoriesObserver = DittoManager.observe<Category>("SELECT * FROM categories") { list ->
                categories = list.sortedBy { it.category_name }
            }
            // The full catalog (400 docs) stays resident: id → name lookups
            // for inventory rows and the low-stock view.
            productsAllObserver = DittoManager.observe<Product>(
                "SELECT * FROM products WHERE deleted = false"
            ) { list -> productsById = list.associateBy { it.product_id } }
            // Inventory is already the selected store's slice (subscription).
            inventoryAllObserver = DittoManager.observe<InventoryItem>(
                "SELECT * FROM inventory WHERE deleted = false"
            ) { items ->
                stockByProduct = items.associateBy { it.product_id }
                // Refresh badges on the visible page when stock changes.
                rows = rows.map { it.copy(stock = stockByProduct[it.product.product_id]) }
            }
            restart(appState)
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }

    fun stop() {
        categoriesObserver?.close()
        productsAllObserver?.close()
        inventoryAllObserver?.close()
        pageObserver?.close()
        countObserver?.close()
        categoriesObserver = null
        productsAllObserver = null
        inventoryAllObserver = null
        pageObserver = null
        countObserver = null
        restartJob?.cancel()
        restartJob = null
        searchJob?.cancel()
        searchJob = null
        startedFor = null
    }

    fun restart(appState: AppState) {
        val previous = restartJob
        restartJob = scope.launch {
            previous?.join()
            if (!isActive) return@launch
            reloadPage(appState)
        }
    }

    private fun reloadPage(appState: AppState) {
        pageObserver?.close()
        countObserver?.close()
        pageObserver = null
        countObserver = null

        // Never render the previous store's rows: clear before re-registering
        // so the skeleton shows instead of stale data.
        if (lastStoreId != appState.selectedStoreId.value) {
            rows = emptyList()
            totalCount = 0
        }
        lastStoreId = appState.selectedStoreId.value

        try {
            if (lowStockOnly) observeLowStockPage() else observeProductsPage()
            error = null
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }

    private fun observeProductsPage() {
        val whereClause: String
        val arguments = mutableMapOf<String, Any?>()
        val categoryId = selectedCategoryId
        if (categoryId != null) {
            whereClause = productsByCategoryWhere
            arguments["categoryId"] = categoryId
        } else {
            whereClause = productsWhere
        }
        countObserver = DittoManager.observe<CountRow>(
            "SELECT COUNT(*) AS count $whereClause", arguments,
        ) { rows -> totalCount = rows.firstOrNull()?.count ?: 0 }
        // Unique tiebreaker: OFFSET paging over a non-unique key can skip or
        // repeat rows across pages.
        val pageQuery = Paging.pageQuery(
            base = "SELECT * $whereClause", orderBy = "product_name, _id", page = page, pageSize = pageSize,
        )
        activeQuery = if (categoryId != null) pageQuery.replace(":categoryId", "'$categoryId'") else pageQuery
        pageObserver = DittoManager.observe<Product>(pageQuery, arguments) { products ->
            rows = products.map { Row(it, stockByProduct[it.product_id]) }
        }
    }

    private fun observeLowStockPage() {
        countObserver = DittoManager.observe<CountRow>(
            "SELECT COUNT(*) AS count $lowStockWhere",
        ) { rows -> totalCount = rows.firstOrNull()?.count ?: 0 }
        val pageQuery = Paging.pageQuery(
            base = "SELECT * $lowStockWhere", orderBy = "stock_level, _id", page = page, pageSize = pageSize,
        )
        activeQuery = pageQuery
        pageObserver = DittoManager.observe<InventoryItem>(pageQuery) { items ->
            rows = items.mapNotNull { item ->
                productsById[item.product_id]?.let { Row(it, item) }
            }
        }
    }

    /// One-shot search with 500 ms debounce — observers are for live screens;
    /// search-as-you-type is a series of point queries (first 50 matches).
    fun search() {
        searchJob?.cancel()
        val term = searchText.trim()
        if (term.isEmpty()) {
            searchResults = null
            return
        }
        searchJob = scope.launch {
            delay(500)
            if (!isActive) return@launch
            try {
                searchResults = DittoManager.fetch<Product>(
                    searchQuery.trimIndent(),
                    mapOf("term" to term, "like" to "%$term%"),
                )
            } catch (e: kotlinx.coroutines.CancellationException) {
                // superseded — not an error
            } catch (e: Exception) {
                error = e.localizedMessage
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ProductsScreen(appState: AppState, onOpenProduct: (Product, InventoryItem?) -> Unit, modifier: Modifier = Modifier) {
    val state = remember { ProductsState() }
    val selectedStoreId by appState.selectedStoreId.collectAsStateWithLifecycle()
    val colors = DittoColors.current

    PublishScreenInfo(
        state.activeQuery.ifEmpty { "SELECT * ${ProductsState.productsWhere} ORDER BY product_name, _id" },
        productsScreenExplanation,
    )

    LaunchedEffect(Unit) { state.start(appState) }
    DisposableEffect(Unit) { onDispose { state.stop() } }
    // Store switch: full restart of the observers (products are global, the
    // inventory slice is per-store).
    val initialStoreId = remember { selectedStoreId }
    LaunchedEffect(selectedStoreId) {
        if (selectedStoreId != initialStoreId) {
            state.stop()
            state.start(appState)
        }
    }

    Column(modifier = modifier) {
        ZavaSearchField(
            value = state.searchText,
            onValueChange = {
                state.searchText = it
                state.search()
            },
            placeholder = "Search name or SKU…",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )

        // FlowRow so chips WRAP instead of clipping on narrow windows
        // (landscape phone, tablet split view).
        FlowRow(
            modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CategoryChip("All", state.selectedCategoryId == null && !state.lowStockOnly) {
                state.selectedCategoryId = null
                state.lowStockOnly = false
                state.page = 1
                state.restart(appState)
            }
            state.categories.forEach { category ->
                CategoryChip(
                    category.category_name,
                    state.selectedCategoryId == category.category_id && !state.lowStockOnly,
                ) {
                    state.selectedCategoryId = category.category_id
                    state.lowStockOnly = false
                    state.page = 1
                    state.restart(appState)
                }
            }
            CategoryChip("⚠ Low stock", state.lowStockOnly) {
                state.lowStockOnly = true
                state.selectedCategoryId = null
                state.page = 1
                state.restart(appState)
            }
        }
        HorizontalDivider()

        Box(modifier = Modifier.weight(1f)) {
            if (state.visibleRows.isEmpty()) {
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
                    items(state.visibleRows, key = { it.id }) { row ->
                        ProductRow(row) { onOpenProduct(row.product, row.stock) }
                        HorizontalDivider(thickness = 0.5.dp, color = colors.borderNormal)
                    }
                }
            }
        }

        if (!state.isSearching) {
            HorizontalDivider()
            PaginationBar(
                totalCount = state.totalCount,
                page = state.page,
                pageSize = state.pageSize,
                pageSizes = listOf(25, 50, 100),
                onPage = { state.page = it; state.restart(appState) },
                onPageSize = { state.pageSize = it; state.restart(appState) },
            )
        }
    }
}

@Composable
private fun CategoryChip(title: String, isSelected: Boolean, onClick: () -> Unit) {
    val colors = DittoColors.current
    Text(
        title,
        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
        color = if (isSelected) colors.foregroundOnBrandPrimary else colors.foregroundNormal,
        modifier = Modifier
            .clip(CircleShape)
            .background(if (isSelected) colors.fillBrandPrimary else colors.surfaceSecondary)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
private fun ProductRow(row: ProductsState.Row, onClick: () -> Unit) {
    val colors = DittoColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(row.product.product_name, color = colors.foregroundNormal)
            Text(
                row.product.sku,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                color = colors.foregroundSubtle,
            )
        }
        row.stock?.let { stock ->
            DittoBadge(
                "${stock.stock_level} in stock",
                if (stock.stock_level < 5) DittoBadgeStatus.Warning else DittoBadgeStatus.Info,
            )
            Spacer(Modifier.padding(4.dp))
        }
        Text(
            Formatters.usd(row.product.base_price),
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            color = colors.foregroundNormal,
        )
    }
}

/// Product detail: this store's stock + shelf location. The location lookup is
/// the composite-_id subfield pattern (inventory._id is {store_id, product_id}).
@Composable
fun ProductDetailScreen(product: Product, stock: InventoryItem?, modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    PublishScreenInfo(ProductDetailQueries.locationQuery.trimIndent(), ProductDetailQueries.explanation)
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        DittoCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(product.product_name, style = MaterialTheme.typography.titleLarge, color = colors.foregroundNormal)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        product.sku,
                        style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
                        color = colors.foregroundSubtle,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        Formatters.usd(product.base_price),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.foregroundNormal,
                    )
                }
                Text(
                    "cost ${Formatters.usd(product.cost)} · margin ${product.gross_margin_percent.toInt()}%",
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.foregroundSubtle,
                )
            }
        }

        DittoCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionHeader("Stock at this store", ProductDetailQueries.locationQuery, ProductDetailQueries.explanation)
                if (stock != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        DittoBadge(
                            "${stock.stock_level} units",
                            if (stock.stock_level < 5) DittoBadgeStatus.Warning else DittoBadgeStatus.Success,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            "Aisle ${stock.location.aisle} · Shelf ${stock.location.shelf} · Bin ${stock.location.bin}",
                            style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
                            color = colors.foregroundNormal,
                        )
                    }
                } else {
                    Text("Not stocked at this store.", color = colors.foregroundSubtle)
                }
            }
        }
    }
}

private const val productsScreenExplanation =
    "The 400-product catalog is subscribed UNFILTERED — every device holds the whole thing, so chips and paging are instant and offline. Pagination is LIMIT/OFFSET in DQL (ORDER BY product_name, _id LIMIT <pageSize> OFFSET <…>) with a live COUNT(*) observer for the total — the query above is the exact paged query running now.\n\nCategory chips filter in the query (category_id), not in memory. \"⚠ Low stock\" pages the inventory collection directly (stock_level < 5). Rows join the paged products with this store's inventory in memory for the stock badges — inventory syncs per-store, so badges climb as the store slice arrives. Search is one-shot (500 ms debounce): exact SKU match OR product-name LIKE, first 50 matches."

private object ProductDetailQueries {
    const val locationQuery = """
        SELECT * FROM inventory
        WHERE _id.store_id = :storeId AND _id.product_id = :productId AND deleted = false
    """
    const val explanation = "inventory._id is a composite key {store_id, product_id}. This query filters on its subfields to find the shelf location (aisle/shelf/bin) of a product at your store — the worker-app \"find it on the shelf\" pattern from the benchmark. Composite-subfield queries need an explicit index (the app creates zava_inventory_store)."
}
