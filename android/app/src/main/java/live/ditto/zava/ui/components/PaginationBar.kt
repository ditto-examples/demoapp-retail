package live.ditto.zava.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import live.ditto.anvil.material3.DittoMonoFontFamily
import live.ditto.zava.model.Paging
import live.ditto.zava.ui.formatted

/// Shared pagination bar (Edge Studio's PaginationControls pattern, Anvil
/// styling): total count, page-size menu, prev/next with "page X of Y".
/// The DQL behind it is `… ORDER BY … LIMIT <pageSize> OFFSET <offset>`.
@Composable
fun PaginationBar(
    totalCount: Int,
    page: Int,
    pageSize: Int,
    pageSizes: List<Int>,
    onPage: (Int) -> Unit,
    onPageSize: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = DittoColors.current
    val pageCount = Paging.pageCount(totalCount, pageSize)

    Surface(modifier = modifier.fillMaxWidth(), color = colors.surface) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "${totalCount.formatted()} total",
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                color = colors.foregroundSubtle,
            )

            Spacer(Modifier.weight(1f))

            var sizeMenuOpen by remember { mutableStateOf(false) }
            Box {
                TextButton(onClick = { sizeMenuOpen = true }) {
                    Text("Show $pageSize", color = colors.foregroundSubtle)
                }
                DropdownMenu(expanded = sizeMenuOpen, onDismissRequest = { sizeMenuOpen = false }) {
                    pageSizes.forEach { size ->
                        DropdownMenuItem(
                            text = { Text("$size per page") },
                            onClick = {
                                sizeMenuOpen = false
                                onPage(1)
                                onPageSize(size)
                            },
                        )
                    }
                }
            }

            IconButton(
                onClick = { onPage(maxOf(1, page - 1)) },
                enabled = page > 1,
                modifier = Modifier.testTag("PaginationPrevButton"),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                    contentDescription = "Previous page",
                    tint = if (page > 1) colors.foregroundNormal else colors.foregroundDisabled,
                )
            }

            Text(
                "$page of $pageCount",
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = DittoMonoFontFamily),
                color = colors.foregroundNormal,
                modifier = Modifier.testTag("PaginationPageIndicator"),
            )

            IconButton(
                onClick = { onPage(minOf(pageCount, page + 1)) },
                enabled = page < pageCount,
                modifier = Modifier.testTag("PaginationNextButton"),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = "Next page",
                    tint = if (page < pageCount) colors.foregroundNormal else colors.foregroundDisabled,
                )
            }
        }
    }
}
