package live.ditto.anvil.material3

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import live.ditto.anvil.tokens.AnvilSemanticColors
import live.ditto.anvil.tokens.AnvilThemeTier
import live.ditto.anvil.tokens.anvilSemanticColors

/** Which Ditto theme the app should resolve to. */
enum class DittoThemeMode {
    /** Follow the system light/dark setting (Android `uiMode`). */
    System,
    Light,
    Dark,
}

/**
 * Ditto brand theme for Android Jetpack Compose apps using the latest
 * `androidx.compose.material3` (including Material 3 Expressive components).
 *
 * Wrap [content] in `DittoTheme` at the root of your app:
 *
 * ```
 * setContent {
 *     DittoTheme {
 *         // Material 3 / Expressive components render with Ditto colors and typography
 *     }
 * }
 * ```
 *
 * @param mode light, dark, or follow-system (default).
 * @param highContrast when `true`, uses Anvil's high-contrast color tier
 *   (mirrors Anvil's `light-high-contrast` / `dark-high-contrast` web themes).
 * @param dynamicColor when `true` on Android 12+, wallpaper-derived dynamic
 *   color replaces the Material color scheme. Ditto typography is kept, and
 *   [DittoColors] still exposes Ditto semantic colors — which keep the
 *   requested tier (including high contrast), so extended semantics stay
 *   Ditto-branded while system surfaces go dynamic. Default is `false` so
 *   Ditto branding is never silently overridden. Note: only the Material
 *   `colorScheme` bypasses the high-contrast tier under dynamic color.
 * @param brandFontFamily optional typeface for display/headline styles —
 *   Kairos Sans is Ditto's brand font but is not bundled for licensing
 *   reasons; supply it here if you have a license. Falls back to Inter.
 * @param content the themed app content.
 */
@Composable
fun DittoTheme(
    mode: DittoThemeMode = DittoThemeMode.System,
    highContrast: Boolean = false,
    dynamicColor: Boolean = false,
    brandFontFamily: FontFamily? = null,
    content: @Composable () -> Unit,
) {
    val dark = when (mode) {
        DittoThemeMode.System -> isSystemInDarkTheme()
        DittoThemeMode.Light -> false
        DittoThemeMode.Dark -> true
    }
    val tier = when {
        dark && highContrast -> AnvilThemeTier.DarkHighContrast
        dark -> AnvilThemeTier.Dark
        highContrast -> AnvilThemeTier.LightHighContrast
        else -> AnvilThemeTier.Light
    }
    val semantic = remember(tier) { anvilSemanticColors(tier) }
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            remember(dark, context) {
                if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
            }
        }
        else -> remember(tier) {
            when (tier) {
                AnvilThemeTier.Light -> anvilLightColorScheme()
                AnvilThemeTier.Dark -> anvilDarkColorScheme()
                AnvilThemeTier.LightHighContrast -> anvilLightHighContrastColorScheme()
                AnvilThemeTier.DarkHighContrast -> anvilDarkHighContrastColorScheme()
            }
        }
    }
    val typography = remember(brandFontFamily) {
        dittoTypography(brandFontFamily = brandFontFamily)
    }
    CompositionLocalProvider(LocalAnvilSemanticColors provides semantic) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = typography,
            content = content,
        )
    }
}

/**
 * The semantic Anvil colors for the current tier. Falls back to the light
 * tier when read outside a [DittoTheme] (e.g. in isolated previews).
 *
 * Uses [compositionLocalOf] so switching theme mode at runtime recomposes
 * everything that reads [DittoColors.current].
 */
val LocalAnvilSemanticColors =
    compositionLocalOf { anvilSemanticColors(AnvilThemeTier.Light) }

/**
 * Access Anvil's extended (semantic) colors that have no Material 3 role —
 * e.g. `DittoColors.current.fillSuccess`, `.borderWarning`, `.codeKeyword`.
 *
 * ```
 * Text("Synced", color = DittoColors.current.fillSuccess)
 * ```
 */
object DittoColors {
    val current: AnvilSemanticColors
        @Composable
        @ReadOnlyComposable
        get() = LocalAnvilSemanticColors.current
}
