package live.ditto.zava

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Handyman
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Receipt
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import kotlinx.serialization.Serializable
import live.ditto.anvil.material3.DittoColors
import live.ditto.anvil.material3.DittoTheme
import live.ditto.zava.model.InventoryItem
import live.ditto.zava.model.Order
import live.ditto.zava.model.Product
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.customers.CustomersScreen
import live.ditto.zava.ui.dashboard.DashboardScreen
import live.ditto.zava.ui.ditto.DittoTabScreen
import live.ditto.zava.ui.ditto.IndexesScreen
import live.ditto.zava.ui.ditto.SyncStatusScreen
import live.ditto.zava.ui.ditto.ToolsScreen
import live.ditto.zava.ui.components.QueryInfoButton
import live.ditto.zava.ui.components.ScreenInfoBus
import live.ditto.zava.ui.orders.OrderDetailScreen
import live.ditto.zava.ui.orders.OrdersScreen
import live.ditto.zava.ui.picker.StorePickerScreen
import live.ditto.zava.ui.products.ProductDetailScreen
import live.ditto.zava.ui.products.ProductsScreen
import live.ditto.zava.ui.queries.BenchmarkDetailScreen
import live.ditto.zava.ui.queries.QueryCatalogScreen

/// Navigation 3 routes — the backstack keys (all @Serializable for state
/// restoration).
sealed interface Route : NavKey {
    @Serializable data object Home : Route
    @Serializable data object Orders : Route
    @Serializable data class OrderDetail(val order: Order) : Route
    @Serializable data object Products : Route
    @Serializable data class ProductDetail(val product: Product, val stock: InventoryItem?) : Route
    @Serializable data object Customers : Route
    @Serializable data object Ditto : Route
    @Serializable data object QueryRunner : Route
    @Serializable data class BenchmarkDetail(val name: String) : Route
    @Serializable data object SyncStatus : Route
    @Serializable data object Indexes : Route
    @Serializable data object Tools : Route
}

private val Route.title: String
    get() = when (this) {
        Route.Home -> "Dashboard"
        Route.Orders -> "Orders"
        is Route.OrderDetail -> "Order"
        Route.Products -> "Products"
        is Route.ProductDetail -> "Product"
        Route.Customers -> "Customers"
        Route.Ditto -> "Ditto"
        Route.QueryRunner -> "Query Runner"
        is Route.BenchmarkDetail -> "Benchmark"
        Route.SyncStatus -> "Sync status"
        Route.Indexes -> "Indexes"
        Route.Tools -> "Ditto tools"
    }

private data class Tab(
    val route: Route,
    val label: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    val iconRes: Int? = null,
)

private val tabs = listOf(
    Tab(Route.Home, "Home", Icons.Filled.Home),
    Tab(Route.Orders, "Orders", Icons.Filled.Receipt),
    Tab(Route.Products, "Products", Icons.Filled.Handyman),
    Tab(Route.Customers, "Customers", Icons.Filled.Groups),
    // The brand mark as the tab icon (NavigationSuite tints it like any tab
    // icon, matching the Swift tab bar's template rendering).
    Tab(Route.Ditto, "Ditto", iconRes = R.drawable.ditto_mark),
)

class MainActivity : ComponentActivity() {

    // Ditto's P2P transports (BLE/LAN/WiFi-Aware) are on by default even in
    // .server connect mode — request the runtime permissions once at launch.
    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // UI-test hook: mirrors the Swift "-resetStoreSelection" launch arg.
        if (intent?.getBooleanExtra("resetStoreSelection", false) == true) {
            getSharedPreferences("zava", MODE_PRIVATE).edit().remove(AppState.KEY_SELECTED_STORE).apply()
        }
        setContent {
            val appState: AppState = viewModel()
            DittoTheme {
                AppRoot(appState)
            }
        }
        requestDittoPermissions()
    }

    private fun requestDittoPermissions() {
        val permissions = buildList {
            if (Build.VERSION.SDK_INT >= 31) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
            } else {
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }
        if (permissions.isNotEmpty()) permissionLauncher.launch(permissions.toTypedArray())
    }
}

@Composable
private fun AppRoot(appState: AppState) {
    val colors = DittoColors.current
    val boot by appState.boot.collectAsStateWithLifecycle()
    val selectedStoreId by appState.selectedStoreId.collectAsStateWithLifecycle()
    val lastError by appState.lastError.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) { appState.bootApp() }

    Surface(modifier = Modifier.fillMaxSize(), color = colors.background) {
        Column {
            lastError?.let { ErrorBanner(it, onDismiss = { appState.dismissError() }) }
            Box(modifier = Modifier.weight(1f)) {
                when (val state = boot) {
                    AppState.Boot.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            CircularProgressIndicator()
                            Text("Starting Ditto…", color = colors.foregroundSubtle)
                        }
                    }
                    AppState.Boot.MissingConfig -> MissingConfigScreen()
                    is AppState.Boot.Failed -> ErrorScreen(state.message)
                    AppState.Boot.Ready -> if (selectedStoreId == null) {
                        StorePickerScreen(appState)
                    } else {
                        MainTabs(appState)
                    }
                }
            }
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    val colors = DittoColors.current
    Surface(
        modifier = Modifier.fillMaxWidth().padding(12.dp),
        color = colors.fillCriticalSecondary,
        shape = RoundedCornerShape(10.dp),
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = colors.fillCritical)
            Text(
                message,
                style = MaterialTheme.typography.bodyMedium,
                color = colors.foregroundNormal,
                maxLines = 3,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onDismiss) {
                Icon(Icons.Filled.Close, contentDescription = "Dismiss", tint = colors.foregroundSubtle)
            }
        }
    }
}

@Composable
private fun MissingConfigScreen() {
    val colors = DittoColors.current
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Ditto credentials missing", style = MaterialTheme.typography.titleLarge, color = colors.foregroundNormal)
            Text(
                "Copy .env.template to .env at the repository root and fill in DITTO_DATABASE_ID, DITTO_DEVELOPMENT_TOKEN, and DITTO_SERVER_URL from the Ditto portal, then rebuild.",
                style = MaterialTheme.typography.bodyMedium,
                color = colors.foregroundSubtle,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ErrorScreen(message: String) {
    val colors = DittoColors.current
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Ditto failed to start", style = MaterialTheme.typography.titleLarge, color = colors.foregroundNormal)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = colors.foregroundSubtle, textAlign = TextAlign.Center)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MainTabs(appState: AppState) {
    val colors = DittoColors.current
    val backStack = rememberNavBackStack(Route.Home)
    val current = backStack.lastOrNull() as? Route ?: Route.Home
    val currentTab = backStack.firstOrNull() as? Route ?: Route.Home

    fun navigate(route: Route) = backStack.add(route)
    fun selectTab(tab: Route) {
        backStack.clear()
        backStack.add(tab)
    }

    NavigationSuiteScaffold(
        navigationSuiteItems = {
            tabs.forEach { tab ->
                item(
                    selected = currentTab == tab.route,
                    onClick = { selectTab(tab.route) },
                    icon = {
                        if (tab.iconRes != null) {
                            Icon(
                                painterResource(tab.iconRes),
                                contentDescription = tab.label,
                                modifier = Modifier.size(24.dp),
                            )
                        } else {
                            Icon(tab.icon!!, contentDescription = tab.label)
                        }
                    },
                    label = {
                        // "Customers" is the long pole: on narrow bars (folded
                        // cover display) the default label size wraps it to a
                        // second line. One line, slightly smaller, ellipsize
                        // as the degradation mode — never a wrap.
                        Text(
                            tab.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.labelMedium.copy(fontSize = 11.sp),
                        )
                    },
                )
            }
        },
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(current.title, fontWeight = FontWeight.SemiBold) },
                    navigationIcon = {
                        if (backStack.size > 1) {
                            IconButton(onClick = { backStack.removeAt(backStack.lastIndex) }) {
                                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                            }
                        }
                    },
                    actions = {
                        // The screen's info action (right side) — each screen
                        // publishes its explainer + the ACTUAL DQL running.
                        ScreenInfoBus.current?.let { (query, explanation) ->
                            QueryInfoButton(
                                query = query,
                                explanation = explanation,
                                contentDescription = "About this screen",
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.surface),
                )
            },
            containerColor = colors.background,
        ) { padding ->
            NavDisplay(
                backStack = backStack,
                modifier = Modifier.padding(padding),
                onBack = { backStack.removeLastOrNull() },
                entryProvider = entryProvider {
                    entry<Route.Home> { DashboardScreen(appState) }
                    entry<Route.Orders> { OrdersScreen(appState, onOpenOrder = { navigate(Route.OrderDetail(it)) }) }
                    entry<Route.OrderDetail> { entry -> OrderDetailScreen(entry.order) }
                    entry<Route.Products> {
                        ProductsScreen(appState, onOpenProduct = { product, stock -> navigate(Route.ProductDetail(product, stock)) })
                    }
                    entry<Route.ProductDetail> { entry -> ProductDetailScreen(entry.product, entry.stock) }
                    entry<Route.Customers> { CustomersScreen(appState) }
                    entry<Route.Ditto> {
                        DittoTabScreen(
                            appState,
                            onOpenQueryRunner = { navigate(Route.QueryRunner) },
                            onOpenSyncStatus = { navigate(Route.SyncStatus) },
                            onOpenIndexes = { navigate(Route.Indexes) },
                            onOpenTools = { navigate(Route.Tools) },
                        )
                    }
                    entry<Route.QueryRunner> { QueryCatalogScreen(onOpenBenchmark = { navigate(Route.BenchmarkDetail(it)) }) }
                    entry<Route.BenchmarkDetail> { entry -> BenchmarkDetailScreen(entry.name, appState) }
                    entry<Route.SyncStatus> { SyncStatusScreen() }
                    entry<Route.Indexes> { IndexesScreen() }
                    entry<Route.Tools> { ToolsScreen(appState) }
                },
            )
        }
    }
}
