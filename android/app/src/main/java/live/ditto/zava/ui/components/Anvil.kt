package live.ditto.zava.ui.components

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import live.ditto.anvil.material3.DittoColors
import live.ditto.anvil.material3.DittoMonoFontFamily

/// The Android faces of the Swift app's Anvil components. The vendored
/// anvil-material3 module is theme-only (colors/typography), so these are
/// thin Material3 wrappers pinned to the Anvil semantic tokens — mirroring the
/// Swift Anvil component styling 1:1.

enum class DittoBadgeStatus { Info, Success, Warning, Critical, Promo }

@Composable
private fun badgeFill(status: DittoBadgeStatus): Color {
    val colors = DittoColors.current
    return when (status) {
        DittoBadgeStatus.Info -> colors.fillInfoSecondary
        DittoBadgeStatus.Success -> colors.fillSuccessSecondary
        DittoBadgeStatus.Warning -> colors.fillWarningSecondary
        DittoBadgeStatus.Critical -> colors.fillCriticalSecondary
        DittoBadgeStatus.Promo -> colors.fillPromoSecondary
    }
}

/// AnvilBadge: medium-weight label on a tonal status capsule.
@Composable
fun DittoBadge(text: String, status: DittoBadgeStatus, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        color = badgeFill(status),
        shape = CircleShape,
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium),
            color = DittoColors.current.foregroundNormal,
        )
    }
}

/// AnvilCard: surface fill, 12dp corners, 1dp normal border, 16dp padding.
@Composable
fun DittoCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier,
        color = DittoColors.current.surface,
        shape = RoundedCornerShape(12.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, DittoColors.current.borderNormal),
    ) {
        androidx.compose.foundation.layout.Column(
            modifier = Modifier.padding(16.dp),
            content = content,
        )
    }
}

enum class DittoButtonVariant { Primary, Secondary, Ghost }

/// AnvilButton: primary = brand fill with on-brand content, secondary =
/// surfaceSecondary, ghost = text-only.
@Composable
fun DittoButton(
    title: String,
    modifier: Modifier = Modifier,
    variant: DittoButtonVariant = DittoButtonVariant.Primary,
    enabled: Boolean = true,
    testTag: String? = null,
    onClick: () -> Unit,
) {
    val colors = DittoColors.current
    val tagged = testTag?.let { modifier.testTag(it) } ?: modifier
    when (variant) {
        DittoButtonVariant.Primary, DittoButtonVariant.Secondary -> Button(
            onClick = onClick,
            enabled = enabled,
            modifier = tagged,
            colors = ButtonDefaults.buttonColors(
                containerColor = if (variant == DittoButtonVariant.Primary) colors.fillBrandPrimary else colors.surfaceSecondary,
                contentColor = if (variant == DittoButtonVariant.Primary) colors.foregroundOnBrandPrimary else colors.foregroundNormal,
                disabledContainerColor = colors.fillDisabled,
                disabledContentColor = colors.foregroundDisabled,
            ),
        ) {
            Text(title)
        }
        DittoButtonVariant.Ghost -> TextButton(onClick = onClick, enabled = enabled, modifier = tagged) {
            Text(title, color = colors.foregroundNormal)
        }
    }
}

/// The standard search field for the list screens: magnifier leading icon and
/// — the parity ask from the iOS `.searchable` control — a × clear affordance
/// whenever the field has text. ImeAction.Search; the debounce lives in the
/// screen state, not here.
@Composable
fun ZavaSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
) {
    val colors = DittoColors.current
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        placeholder = { Text(placeholder, color = colors.foregroundSubtle) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        shape = RoundedCornerShape(12.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = colors.surface,
            unfocusedContainerColor = colors.surface,
            focusedBorderColor = colors.borderStrong,
            unfocusedBorderColor = colors.borderNormal,
            focusedTextColor = colors.foregroundNormal,
            unfocusedTextColor = colors.foregroundNormal,
            cursorColor = colors.foregroundNormal,
        ),
        leadingIcon = {
            Icon(Icons.Filled.Search, contentDescription = null, tint = colors.foregroundSubtle)
        },
        trailingIcon = {
            if (value.isNotEmpty()) {
                IconButton(onClick = { onValueChange("") }) {
                    Icon(Icons.Filled.Close, contentDescription = "Clear search", tint = colors.foregroundSubtle)
                }
            }
        },
    )
}

/// Monospaced, selectable code block (the DQL viewer — IBM Plex Mono on the
/// Anvil code colors, rounded codeBackground panel).
@Composable
fun CodeBlock(text: String, modifier: Modifier = Modifier, fontSizeSp: Int = 12) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = DittoColors.current.codeBackground,
        shape = RoundedCornerShape(8.dp),
    ) {
        SelectionContainer {
            Text(
                text = text,
                modifier = Modifier.padding(10.dp),
                style = MaterialTheme.typography.bodySmall.copy(
                    fontFamily = DittoMonoFontFamily,
                    fontSize = fontSizeSp.sp,
                ),
                color = DittoColors.current.codeForeground,
            )
        }
    }
}
