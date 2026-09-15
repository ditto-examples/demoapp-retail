package live.ditto.zava.ui.customers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
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
import live.ditto.zava.model.Customer
import live.ditto.zava.model.Paging
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.components.DittoBadge
import live.ditto.zava.ui.components.DittoBadgeStatus
import live.ditto.zava.ui.components.PaginationBar
import live.ditto.zava.ui.components.PublishScreenInfo
import live.ditto.zava.ui.components.SkeletonRows
import live.ditto.zava.ui.components.ZavaSearchField
import live.ditto.zava.ui.formatted

/// The full 50K-row customer directory, synced unfiltered
/// (a walk-in could be anyone), PAGED with
/// LIMIT/OFFSET so the demo handles the full directory gracefully. "This store
/// only" filters inside the query (customers__select__by_primary_store_id_*),
/// not in memory. The search field runs one-shot point queries (debounced).
class CustomersState {
    var customers by mutableStateOf<List<Customer>>(emptyList())
    var totalCount by mutableStateOf(0)
    var page by mutableStateOf(1)
    var pageSize by mutableStateOf(25)
    var thisStoreOnly by mutableStateOf(false)
    var searchText by mutableStateOf("")
    var searchResults by mutableStateOf<List<Customer>?>(null)
    var error by mutableStateOf<String?>(null)

    /// The exact paged query currently observed (store arg resolved inline) —
    /// the app bar's info sheet shows this, not a template.
    var activeQuery by mutableStateOf("")

    private var pageObserver: DittoStoreObserver? = null
    private var countObserver: DittoStoreObserver? = null
    private var restartJob: Job? = null
    private var searchJob: Job? = null
    private var lastStoreId: String? = null
    private var started = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    companion object {
        const val directoryWhere = "FROM customers WHERE deleted = false"
        const val storeWhere = "FROM customers WHERE primary_store_id = :storeId AND deleted = false"

        /// The store filter lives IN the query (the benchmark's
        /// customers__select__by_primary_store_id shape), not in memory.
        fun whereClause(thisStoreOnly: Boolean, storeId: String?): String =
            if (thisStoreOnly && storeId != null) storeWhere else directoryWhere

        /// customers__select__by_email_* — the benchmark's indexed/no-index
        /// pair is runnable side-by-side in the Query Runner tab.
        const val emailQuery = "SELECT * FROM customers WHERE email = :email AND deleted = false"
        const val nameQuery = """
            SELECT * FROM customers WHERE deleted = false
            AND (first_name ILIKE :like OR last_name ILIKE :like) ORDER BY last_name LIMIT 50
        """
    }

    val isSearching: Boolean get() = searchResults != null
    val visibleCustomers: List<Customer> get() = searchResults ?: customers

    fun start(appState: AppState) {
        if (started) return
        started = true
        restart(appState)
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
        started = false
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

        // Never render the previous store's rows.
        val storeId = appState.selectedStoreId.value
        if (lastStoreId != storeId) {
            customers = emptyList()
            totalCount = 0
        }
        lastStoreId = storeId

        val where = whereClause(thisStoreOnly, storeId)
        val arguments = mutableMapOf<String, Any?>()
        if (thisStoreOnly && storeId != null) {
            arguments["storeId"] = storeId
        }

        try {
            countObserver = DittoManager.observe<CountRow>(
                "SELECT COUNT(*) AS count $where", arguments,
            ) { rows ->
                totalCount = rows.firstOrNull()?.count ?: 0
                // Count shrank under the current page — clamp and restart, or
                // the OFFSET page returns nothing and skeletons sit forever.
                val clamped = Paging.clampPage(page, totalCount, pageSize)
                if (clamped != page) {
                    page = clamped
                    restart(appState)
                }
            }
            val pageQuery = Paging.pageQuery(
                base = "SELECT * $where",
                orderBy = "last_name, first_name, _id",
                page = page,
                pageSize = pageSize,
            )
            activeQuery = if (thisStoreOnly && storeId != null) {
                pageQuery.replace(":storeId", "'$storeId'")
            } else {
                pageQuery
            }
            pageObserver = DittoManager.observe<Customer>(pageQuery, arguments) { customers = it }
            error = null
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }

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
                searchResults = if (term.contains("@")) {
                    // exact-email lookup — the benchmark's indexed pair member
                    DittoManager.fetch<Customer>(emailQuery, mapOf("email" to term))
                } else {
                    DittoManager.fetch<Customer>(nameQuery.trimIndent(), mapOf("like" to "$term%"))
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                // superseded — not an error
            } catch (e: Exception) {
                error = e.localizedMessage
            }
        }
    }
}

private const val customersScreenExplanation =
    "The 50K-row customer directory is subscribed UNFILTERED (a walk-in could be anyone), so this screen pages entirely on-device: LIMIT/OFFSET for the slice (ORDER BY last_name, first_name, _id) plus a live COUNT(*) observer for the total — the query above is the exact paged query running now.\n\n\"This store only\" filters IN the query (primary_store_id = your store), not in memory. Search: an '@' runs an exact-email lookup (run the customers__select__by_id / indexed pairs side by side in the Query Runner); otherwise a name-prefix LIKE on first/last name, first 50 matches."

@Composable
fun CustomersScreen(appState: AppState, modifier: Modifier = Modifier) {
    val state = remember { CustomersState() }
    val selectedStoreId by appState.selectedStoreId.collectAsStateWithLifecycle()
    val colors = DittoColors.current

    PublishScreenInfo(
        state.activeQuery.ifEmpty { "SELECT * ${CustomersState.directoryWhere} ORDER BY last_name, first_name, _id" },
        customersScreenExplanation,
    )

    LaunchedEffect(Unit) { state.start(appState) }
    DisposableEffect(Unit) { onDispose { state.stop() } }
    val initialStoreId = remember { selectedStoreId }
    LaunchedEffect(selectedStoreId) {
        if (selectedStoreId != initialStoreId) {
            state.page = 1
            state.restart(appState)
        }
    }

    Column(modifier = modifier) {
        ZavaSearchField(
            value = state.searchText,
            onValueChange = {
                state.searchText = it
                state.search()
            },
            placeholder = "Search name, or exact email…",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        Row(
            modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            // M3 list-item spacing: 16dp between label text and the control.
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "This store only",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.foregroundSubtle,
            )
            Switch(
                checked = state.thisStoreOnly,
                onCheckedChange = {
                    state.thisStoreOnly = it
                    state.page = 1
                    state.restart(appState)
                },
            )
            Spacer(Modifier.weight(1f))
            if (!state.isSearching) {
                Text(
                    "${state.totalCount.formatted()} customers",
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                    color = colors.foregroundSubtle,
                )
            }
        }
        HorizontalDivider()

        Box(modifier = Modifier.weight(1f)) {
            if (state.visibleCustomers.isEmpty()) {
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
                    items(state.visibleCustomers, key = { it.id }) { customer ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(customer.displayName, color = colors.foregroundNormal)
                            Text(
                                customer.email,
                                style = MaterialTheme.typography.bodyMedium,
                                color = colors.foregroundSubtle,
                            )
                        }
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
