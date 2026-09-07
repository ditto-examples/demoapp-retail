package live.ditto.zava.ui.queries

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import live.ditto.anvil.material3.DittoColors
import live.ditto.anvil.material3.DittoMonoFontFamily
import live.ditto.zava.data.DittoManager
import live.ditto.zava.model.BenchmarkCatalog
import live.ditto.zava.model.BenchmarkEntry
import live.ditto.zava.model.BenchmarkRunResult
import live.ditto.zava.model.PreparedBenchmark
import live.ditto.zava.model.QueryPreparation
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.components.CodeBlock
import live.ditto.zava.ui.components.DittoBadge
import live.ditto.zava.ui.components.DittoBadgeStatus
import live.ditto.zava.ui.components.DittoButton
import live.ditto.zava.ui.components.DittoCard
import live.ditto.zava.ui.components.SuppressScreenInfo
import live.ditto.zava.ui.formatted
import java.util.Locale
import java.util.UUID

private fun categoryStatus(category: String): DittoBadgeStatus = when {
    category == "SELECT" || category == "GUARD" -> DittoBadgeStatus.Info
    category == "INDEX_SELECT" -> DittoBadgeStatus.Promo
    category == "AGGREGATION" || category.startsWith("JOIN_") -> DittoBadgeStatus.Success
    category == "INSERT" || category == "UPSERT" -> DittoBadgeStatus.Warning
    category == "UPDATE" || category == "DELETE" || category == "EVICT" -> DittoBadgeStatus.Critical
    else -> DittoBadgeStatus.Info
}

@Composable
fun CategoryBadge(category: String) {
    DittoBadge(category, categoryStatus(category))
}

private fun loadCatalog(context: android.content.Context): BenchmarkCatalog {
    val text = context.assets.open("benchmarks.json").bufferedReader().use { it.readText() }
    return BenchmarkCatalog.parse(text)
}

@Composable
fun QueryCatalogScreen(onOpenBenchmark: (String) -> Unit, modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    val context = LocalContext.current
    var catalog by remember { mutableStateOf<BenchmarkCatalog?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    // No app-bar info here — the pushed catalog must not inherit the Ditto
    // tab's entry from the screen-info stack.
    SuppressScreenInfo()

    LaunchedEffect(Unit) {
        try {
            catalog = loadCatalog(context)
        } catch (e: Exception) {
            error = e.localizedMessage
        }
    }

    when {
        catalog == null && error == null -> Box(
            modifier = modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                CircularProgressIndicator()
                Text("Loading benchmark catalog…", color = colors.foregroundSubtle)
            }
        }
        error != null -> Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(24.dp),
            ) {
                Text("Catalog unavailable", style = MaterialTheme.typography.titleMedium, color = colors.foregroundNormal)
                Text(error ?: "", style = MaterialTheme.typography.bodyMedium, color = colors.foregroundSubtle)
            }
        }
        else -> LazyColumn(modifier = modifier.fillMaxSize()) {
            catalog!!.groups.forEach { group ->
                stickyHeader {
                    Surface(color = colors.background) {
                        Text(
                            "${group.collection} (${group.entries.size})",
                            style = MaterialTheme.typography.titleSmall,
                            color = colors.foregroundSubtle,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                }
                items(group.entries.size) { index ->
                    val (name, entry) = group.entries[index]
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onOpenBenchmark(name) }
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            name,
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                            color = colors.foregroundNormal,
                        )
                        CategoryBadge(entry.category)
                    }
                    HorizontalDivider(thickness = 0.5.dp, color = colors.borderNormal)
                }
            }
        }
    }
}

@Composable
fun BenchmarkDetailScreen(name: String, appState: AppState, modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val selectedStoreId by appState.selectedStoreId.collectAsStateWithLifecycle()

    var entry by remember { mutableStateOf<BenchmarkEntry?>(null) }
    var loadError by remember { mutableStateOf<String?>(null) }
    // The DQL is already on this screen (query blocks) — no app-bar info here.
    SuppressScreenInfo()
    LaunchedEffect(Unit) {
        try {
            entry = loadCatalog(context).entries.firstOrNull { it.first == name }?.second
        } catch (e: Exception) {
            loadError = e.localizedMessage
        }
    }

    var iterations by remember { mutableIntStateOf(10) }
    var isRunning by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<BenchmarkRunResult?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    var showMutationConfirm by remember { mutableStateOf(false) }

    /// The id the NEXT run will use — the DQL on screen is exactly the DQL
    /// that will execute. Regenerated after every run.
    var runId by remember { mutableStateOf(UUID.randomUUID().toString().take(8)) }

    val currentEntry = entry
    if (loadError != null) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            DittoBadge(loadError!!, DittoBadgeStatus.Critical)
        }
        return
    }
    if (currentEntry == null) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }

    val prepared: PreparedBenchmark = QueryPreparation.prepare(
        name = name,
        entry = currentEntry,
        storeId = selectedStoreId ?: "store_seattle",
        runId = runId,
    )

    fun runNow() {
        isRunning = true
        result = null
        runError = null
        val runIdForThisRun = runId // capture; preview and execution share it
        scope.launch {
            try {
                val run = QueryPreparation.prepare(
                    name = name,
                    entry = currentEntry,
                    storeId = selectedStoreId ?: "store_seattle",
                    runId = runIdForThisRun,
                )
                result = DittoManager.runBenchmark(run, iterations)
            } catch (e: CancellationException) {
                // view torn down mid-run — not an error state
            } catch (e: Exception) {
                runError = e.localizedMessage
            }
            runId = UUID.randomUUID().toString().take(8) // fresh ids for the NEXT run
            isRunning = false
        }
    }

    if (showMutationConfirm) {
        AlertDialog(
            onDismissRequest = { showMutationConfirm = false },
            title = { Text("Run a mutating benchmark?") },
            text = {
                Text(
                    "This ${currentEntry.category} benchmark writes a synthetic document. On a synced device that write replicates to Big Peer; the runner uses fresh per-run ids and cleans up with a propagating DELETE (not EVICT, which is local-only)."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showMutationConfirm = false
                        runNow()
                    },
                ) { Text("Run", color = DittoColors.current.fillCritical) }
            },
            dismissButton = {
                TextButton(onClick = { showMutationConfirm = false }) { Text("Cancel") }
            },
        )
    }

    Box(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp)
                .padding(bottom = 88.dp), // room for the floating run bar
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    name,
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
                    color = colors.foregroundNormal,
                )
                CategoryBadge(currentEntry.category)
            }

            DittoCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    QueryBlock("Query", prepared.query)
                    if (prepared.preQueries.isNotEmpty()) {
                        QueryBlock("Pre-queries (run once)", prepared.preQueries.joinToString("\n"))
                    }
                    if (prepared.postQueries.isNotEmpty()) {
                        QueryBlock("Post-queries (run once)", prepared.postQueries.joinToString("\n"))
                    }
                }
            }

            if (prepared.substitutions.isNotEmpty()) {
                DittoCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            "Substitutions for a synced device",
                            style = MaterialTheme.typography.titleSmall,
                            color = colors.foregroundNormal,
                        )
                        prepared.substitutions.forEach { note ->
                            Text(
                                "• $note",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.foregroundSubtle,
                            )
                        }
                    }
                }
            }

            if (result != null || runError != null) {
                DittoCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        result?.let { r ->
                            ResultRow("Result count", "${r.resultCount.formatted()} rows")
                            currentEntry.expected_count?.let { expected ->
                                ResultRow("Expected on full dataset", "${expected.formatted()} rows")
                            }
                            ResultRow("Mean", "%.2f ms".format(Locale.US, r.stats.meanMs))
                            ResultRow("Median", "%.2f ms".format(Locale.US, r.stats.medianMs))
                            ResultRow("p95", "%.2f ms".format(Locale.US, r.stats.p95Ms))
                            ResultRow("Min / Max", "%.2f / %.2f ms".format(Locale.US, r.stats.minMs, r.stats.maxMs))
                            Text(
                                "${r.iterations} timed iterations, execution only (no rendering). The benchmark harness uses pilot + warmup + 50 iterations; this screen keeps it simple. The expected count comes from the suite's full-dataset oracle — on a sliced load (--size below 100k) smaller counts are correct, not a bug.",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.foregroundSubtle,
                            )
                        }
                        runError?.let { DittoBadge(it, DittoBadgeStatus.Critical) }
                    }
                }
            }
        }

        // Floating run toolbar (Edge Studio DetailBottomBar pattern).
        Surface(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 16.dp)
                .padding(bottom = 8.dp)
                .fillMaxWidth(),
            color = colors.surface,
            shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
            tonalElevation = 2.dp,
            shadowElevation = 4.dp,
            border = androidx.compose.foundation.BorderStroke(1.dp, colors.borderNormal),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                IconButton(
                    onClick = { iterations = maxOf(1, iterations - if (iterations > 10) 10 else 1) },
                    enabled = !isRunning,
                    modifier = Modifier.testTag("IterationsMinus"),
                ) {
                    Icon(Icons.Filled.Remove, contentDescription = "Fewer iterations", tint = colors.foregroundNormal)
                }
                Text(
                    "×$iterations",
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
                    color = colors.foregroundNormal,
                )
                IconButton(
                    onClick = { iterations = minOf(100, iterations + if (iterations >= 10) 10 else 1) },
                    enabled = !isRunning,
                    modifier = Modifier.testTag("IterationsPlus"),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = "More iterations", tint = colors.foregroundNormal)
                }
                Spacer(Modifier.weight(1f))
                if (isRunning) {
                    CircularProgressIndicator(modifier = Modifier.padding(end = 8.dp), strokeWidth = 2.dp)
                    Text("Running…", style = MaterialTheme.typography.bodyMedium, color = colors.foregroundSubtle)
                } else {
                    DittoButton(
                        if (currentEntry.isMutating) "Run (writes data)" else "Run benchmark",
                        testTag = "RunBenchmarkButton",
                    ) {
                        if (currentEntry.isMutating) showMutationConfirm = true else runNow()
                    }
                }
            }
        }
    }
}

@Composable
private fun QueryBlock(title: String, text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.labelSmall,
            color = DittoColors.current.codeMuted,
        )
        CodeBlock(text, fontSizeSp = 12)
    }
}

@Composable
private fun ResultRow(label: String, value: String) {
    val colors = DittoColors.current
    Row {
        Text(label, color = colors.foregroundSubtle)
        Spacer(Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium.copy(fontFamily = DittoMonoFontFamily),
            color = colors.foregroundNormal,
        )
    }
}
