package live.ditto.anvil.material3

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight

/**
 * Ditto UI sans typeface (Inter, OFL-licensed) bundled with the library.
 */
val DittoFontFamily: FontFamily = FontFamily(
    Font(R.font.inter_regular, FontWeight.Normal),
    Font(R.font.inter_medium, FontWeight.Medium),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
    Font(R.font.inter_bold, FontWeight.Bold),
)

/**
 * Ditto monospace typeface (IBM Plex Mono, OFL-licensed) bundled with the
 * library. Use for code samples, keys, and other literal text.
 */
val DittoMonoFontFamily: FontFamily = FontFamily(
    Font(R.font.ibm_plex_mono_regular, FontWeight.Normal),
    Font(R.font.ibm_plex_mono_bold, FontWeight.Bold),
    Font(R.font.ibm_plex_mono_italic, FontWeight.Normal, FontStyle.Italic),
)

/**
 * Builds the Anvil [Typography] for Material 3.
 *
 * Sizes follow Material's defaults (platform consistency). Ditto's typefaces
 * carry the brand:
 * - [brandFontFamily] is used for `display*` and `headline*` styles. Pass the
 *   Kairos Sans variable font here for the full Ditto look; Kairos is a
 *   commercial Monotype typeface and is intentionally **not** bundled with
 *   this library, so the default falls back to [fontFamily] (Inter).
 * - [fontFamily] (Inter) is used for `title*`, `body*`, and `label*`.
 */
fun dittoTypography(
    fontFamily: FontFamily = DittoFontFamily,
    brandFontFamily: FontFamily? = null,
): Typography {
    val brand = brandFontFamily ?: fontFamily
    val base = Typography()
    return Typography(
        displayLarge = base.displayLarge.copy(fontFamily = brand),
        displayMedium = base.displayMedium.copy(fontFamily = brand),
        displaySmall = base.displaySmall.copy(fontFamily = brand),
        headlineLarge = base.headlineLarge.copy(fontFamily = brand),
        headlineMedium = base.headlineMedium.copy(fontFamily = brand),
        headlineSmall = base.headlineSmall.copy(fontFamily = brand),
        titleLarge = base.titleLarge.copy(fontFamily = fontFamily),
        titleMedium = base.titleMedium.copy(fontFamily = fontFamily),
        titleSmall = base.titleSmall.copy(fontFamily = fontFamily),
        bodyLarge = base.bodyLarge.copy(fontFamily = fontFamily),
        bodyMedium = base.bodyMedium.copy(fontFamily = fontFamily),
        bodySmall = base.bodySmall.copy(fontFamily = fontFamily),
        labelLarge = base.labelLarge.copy(fontFamily = fontFamily),
        labelMedium = base.labelMedium.copy(fontFamily = fontFamily),
        labelSmall = base.labelSmall.copy(fontFamily = fontFamily),
    )
}

/** Code text style built on [DittoMonoFontFamily]. */
fun dittoCodeStyle(base: TextStyle): TextStyle =
    base.copy(fontFamily = DittoMonoFontFamily)
