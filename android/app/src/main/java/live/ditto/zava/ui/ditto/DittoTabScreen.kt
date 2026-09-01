package live.ditto.zava.ui.ditto

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
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ditto.kotlin.DittoStoreObserver
import com.ditto.tools.toolsviewer.DittoToolsViewer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import live.ditto.anvil.material3.DittoColors
import live.ditto.anvil.material3.DittoMonoFontFamily
import live.ditto.zava.data.DittoManager
import live.ditto.zava.model.IndexInfo
import live.ditto.zava.model.SyncStatusInfo
import live.ditto.zava.model.toPlainMap
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.components.DittoBadge
import live.ditto.zava.ui.components.DittoBadgeStatus
import live.ditto.zava.ui.components.PublishScreenInfo
import live.ditto.zava.ui.components.SuppressScreenInfo

/// The Ditto system tab: Query Runner, live system:* viewers, the official
/// tools menu, and Switch Store.

@Composable
fun DittoTabScreen(
    appState: AppState,
    onOpenQueryRunner: () -> Unit,
    onOpenSyncStatus: () -> Unit,
    onOpenIndexes: () -> Unit,
    onOpenTools: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = DittoColors.current
    val ditto by appState.ditto.collectAsStateWithLifecycle()

    PublishScreenInfo(SYNC_STATUS_QUERY, dittoTabExplanation)

    LazyColumn(modifier = modifier.fillMaxSize()) {
        item {
            DittoRow("Query Runner", onOpenQueryRunner)
            Text(
                "Browse and run the 72-query retail benchmark catalog against the synced store, with timing.",
                style = MaterialTheme.typography.bodySmall,
                color = colors.foregroundSubtle,
                modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp),
            )
        }
        item {
            DittoRow("Sync status", onOpenSyncStatus)
            DittoRow("Indexes", onOpenIndexes)
            Text(
                "Live views over Ditto's system:data_sync_info and system:indexes virtual collections.",
                style = MaterialTheme.typography.bodySmall,
                color = colors.foregroundSubtle,
                modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp),
            )
        }
        if (ditto != null) {
            item {
                DittoRow("Ditto tools", onOpenTools)
                Text(
                    "The official Ditto tools viewer (ditto-tools-android).",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.foregroundSubtle,
                    modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp),
                )
            }
        }
        item {
            TextButton(onClick = { appState.switchStore() }, modifier = Modifier.padding(horizontal = 4.dp)) {
                Text("Switch store", color = DittoColors.current.fillCritical)
            }
            Text(
                "Returns to the store picker. The current store keeps syncing until you pick a new one — picking it cancels its subscriptions, evicts its local data (EVICT — local only), and subscribes to the new store.",
                style = MaterialTheme.typography.bodySmall,
                color = colors.foregroundSubtle,
                modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp),
            )
        }
    }
}

@Composable
private fun DittoRow(title: String, onClick: () -> Unit) {
    val colors = DittoColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = colors.foregroundNormal, style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.weight(1f))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.foregroundSubtle)
    }
}

private const val dittoTabExplanation =
    "System & tools for the synced store. Query Runner browses and times the 72-query benchmark catalog against the live synced store. Sync status and Indexes are live views over Ditto's system:data_sync_info and system:indexes virtual collections (the query above). Ditto tools is the official diagnostic viewer. Switch store returns to the picker: picking a new store cancels the per-store subscriptions, EVICTs the old store's local data (EVICT is local-only — the difference from DELETE is a teaching moment), and subscribes to the new store."

// MARK: - Sync status (system:data_sync_info)

private const val SYNC_STATUS_QUERY = "SELECT * FROM system:data_sync_info"

private const val syncStatusExplanation =
    "Live rows from Ditto's system:data_sync_info virtual collection — one per sync session (Big Peer plus any mesh peers), each with its session status and synced commit id. Watch it during a store switch: the old subscription drains and the new store's slice starts filling in."

private const val indexesExplanation =
    "Live rows from Ditto's system:indexes virtual collection — every index on the local store. Note the app's zava_* indexes (created at startup to back the per-store subscriptions; app-namespaced so the Query Runner's benchmark cleanup can't drop them) alongside any indexes a benchmark created and dropped during a run."

@Composable
fun SyncStatusScreen(modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    var rows by remember { mutableStateOf<List<SyncStatusInfo>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }

    PublishScreenInfo(SYNC_STATUS_QUERY, syncStatusExplanation)

    DisposableEffect(Unit) {
        var observer: DittoStoreObserver? = null
        try {
            observer = DittoManager.observeRawJson(SYNC_STATUS_QUERY) { jsonRows ->
                rows = jsonRows.mapNotNull { row ->
                    runCatching {
                        SyncStatusInfo.from(Json.parseToJsonElement(row).jsonObject.toPlainMap())
                    }.getOrNull()
                }
            }
        } catch (e: Exception) {
            error = e.localizedMessage
        }
        onDispose { observer?.close() }
    }

    if (rows.isEmpty()) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(24.dp),
            ) {
                if (error != null) {
                    DittoBadge(error!!, DittoBadgeStatus.Critical)
                } else {
                    CircularProgressIndicator()
                    Text("No sync sessions yet", style = MaterialTheme.typography.titleMedium, color = colors.foregroundNormal)
                    Text(
                        "Status appears once sync sessions establish.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.foregroundSubtle,
                    )
                }
            }
        }
    } else {
        LazyColumn(modifier = modifier.fillMaxSize()) {
            items(rows, key = { it.id }) { row ->
                Column(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        row.id,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                        color = colors.foregroundNormal,
                        maxLines = 2,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        DittoBadge(
                            if (row.isDittoServer) "Big Peer" else "peer",
                            if (row.isDittoServer) DittoBadgeStatus.Promo else DittoBadgeStatus.Info,
                        )
                        DittoBadge(
                            row.syncSessionStatus,
                            if (row.syncSessionStatus == "Connected") DittoBadgeStatus.Success else DittoBadgeStatus.Warning,
                        )
                        row.syncedUpToLocalCommitId?.let { commit ->
                            Text(
                                "commit $commit",
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                                color = colors.foregroundSubtle,
                            )
                        }
                    }
                }
                HorizontalDivider(thickness = 0.5.dp, color = colors.borderNormal)
            }
        }
    }
}

// MARK: - Indexes (system:indexes)

private const val INDEXES_QUERY = "SELECT * FROM system:indexes"

@Composable
fun IndexesScreen(modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    var rows by remember { mutableStateOf<List<IndexInfo>>(emptyList()) }

    PublishScreenInfo(INDEXES_QUERY, indexesExplanation)

    DisposableEffect(Unit) {
        var observer: DittoStoreObserver? = null
        try {
            observer = DittoManager.observeRawJson(INDEXES_QUERY) { jsonRows ->
                rows = jsonRows.mapNotNull { row ->
                    runCatching {
                        IndexInfo.from(Json.parseToJsonElement(row).jsonObject.toPlainMap())
                    }.getOrNull()
                }.sortedBy { it.id }
            }
        } catch (_: Exception) {
            // rows stay empty; the list shows nothing (matches Swift: no empty state here)
        }
        onDispose { observer?.close() }
    }

    LazyColumn(modifier = modifier.fillMaxSize()) {
        items(rows, key = { it.id }) { row ->
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    row.id,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                    color = colors.foregroundNormal,
                )
                if (row.definition.isNotEmpty()) {
                    Text(
                        row.definition,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                        color = colors.foregroundSubtle,
                    )
                }
            }
            HorizontalDivider(thickness = 0.5.dp, color = colors.borderNormal)
        }
    }
}

// MARK: - Official Ditto tools viewer

@Composable
fun ToolsScreen(appState: AppState, modifier: Modifier = Modifier) {
    val ditto by appState.ditto.collectAsStateWithLifecycle()
    val instance = ditto
    SuppressScreenInfo() // the tools viewer is Ditto's own diagnostic UI
    if (instance == null) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Ditto not open", color = DittoColors.current.foregroundSubtle)
        }
    } else {
        DittoToolsViewer(ditto = instance, modifier = modifier.fillMaxSize())
    }
}
