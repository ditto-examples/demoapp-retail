package live.ditto.zava.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import live.ditto.anvil.material3.DittoColors

/// Every data surface shows the ACTUAL DQL behind it (not a template) in an
/// info sheet — the app's core teaching move.

@Composable
fun QueryInfoButton(query: String, explanation: String, modifier: Modifier = Modifier) {
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }, modifier = modifier) {
        Icon(
            Icons.Filled.Info,
            contentDescription = "About this query",
            tint = DittoColors.current.foregroundSubtle,
        )
    }
    if (open) {
        QueryInfoSheet(query = query, explanation = explanation, onDismiss = { open = false })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QueryInfoSheet(query: String, explanation: String, onDismiss: () -> Unit) {
    val colors = DittoColors.current
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.surface) {
        Column {
            // Custom header row (mirrors the Swift sheet — close × in the row).
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "About this data",
                    style = MaterialTheme.typography.titleMedium,
                    color = colors.foregroundNormal,
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss, modifier = Modifier.testTag("queryInfo.close")) {
                    Icon(Icons.Filled.Close, contentDescription = "Close", tint = colors.foregroundSubtle)
                }
            }
            HorizontalDivider()
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "The DQL behind this",
                        style = MaterialTheme.typography.titleSmall,
                        color = colors.foregroundNormal,
                    )
                    CodeBlock(query, fontSizeSp = 13)
                }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "What it does",
                        style = MaterialTheme.typography.titleSmall,
                        color = colors.foregroundNormal,
                    )
                    Text(
                        explanation,
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.foregroundSubtle,
                    )
                }
                Text(
                    "Tip: every query in the app runs against data synced by Ditto — offline-first, live-updating.",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.foregroundSubtle,
                )
            }
        }
    }
}

/// Card-section header: title + optional info button, the recurring pattern.
@Composable
fun SectionHeader(title: String, query: String? = null, explanation: String? = null, trailing: (@Composable () -> Unit)? = null) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleSmall,
            color = DittoColors.current.foregroundNormal,
        )
        Spacer(Modifier.weight(1f))
        trailing?.invoke()
        if (query != null && explanation != null) {
            QueryInfoButton(query = query, explanation = explanation)
        }
    }
}
