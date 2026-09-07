package live.ditto.zava.ui.picker

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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import live.ditto.anvil.material3.DittoColors
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.components.DittoBadge
import live.ditto.zava.ui.components.DittoBadgeStatus

/// On-demand store picker (Dashboard header menu / "Switch store" on the
/// Ditto tab): pick one of the 8 Zava stores (synced over the always-on
/// shared `SELECT * FROM stores` subscription). First launch skips this
/// screen: the app auto-selects the loader-flagged smallest-order store
/// (`demo_default`). Persisted via SharedPreferences; re-picking switches
/// subscriptions.
@Composable
fun StorePickerScreen(appState: AppState, modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    val stores by appState.stores.collectAsStateWithLifecycle()

    Column(modifier = modifier.fillMaxSize()) {
        Text(
            "Choose your store",
            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
            color = colors.foregroundNormal,
            modifier = Modifier.padding(16.dp),
        )
        HorizontalDivider()
        if (stores.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.padding(24.dp),
                ) {
                    CircularProgressIndicator()
                    Text(
                        "Waiting for the store catalog to sync…",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.foregroundSubtle,
                    )
                    Text(
                        "No data yet? Run scripts/load_data.py to seed Big Peer.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.foregroundSubtle,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        } else {
            LazyColumn {
                items(stores, key = { it.id }) { store ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { appState.selectStore(store.store_id) }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                store.store_name,
                                style = MaterialTheme.typography.titleMedium,
                                color = colors.foregroundNormal,
                            )
                            Text(
                                "${store.location.city}, ${store.location.state}",
                                style = MaterialTheme.typography.bodyMedium,
                                color = colors.foregroundSubtle,
                            )
                        }
                        Spacer(Modifier.weight(1f))
                        if (store.is_online) {
                            DittoBadge("online", DittoBadgeStatus.Promo)
                            Spacer(Modifier.padding(4.dp))
                        }
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = colors.foregroundSubtle,
                        )
                    }
                    HorizontalDivider(thickness = 0.5.dp, color = colors.borderNormal)
                }
            }
        }
    }
}
