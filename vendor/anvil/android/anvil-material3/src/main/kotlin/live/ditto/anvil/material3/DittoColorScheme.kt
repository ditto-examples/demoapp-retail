package live.ditto.anvil.material3

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import live.ditto.anvil.tokens.AnvilDarkHighContrastPalette
import live.ditto.anvil.tokens.AnvilDarkPalette
import live.ditto.anvil.tokens.AnvilLightHighContrastPalette
import live.ditto.anvil.tokens.AnvilLightPalette
import live.ditto.anvil.tokens.AnvilSemanticColors
import live.ditto.anvil.tokens.AnvilThemeTier
import live.ditto.anvil.tokens.anvilSemanticColors

/**
 * Maps an [AnvilSemanticColors] tier onto a Material 3 [ColorScheme].
 *
 * Applied decisions (see docs/anvil-android-material-plan.md):
 * - `primary` is Anvil's brand fill. Light tier: black fill with **white
 *   content** (readability). Dark/HC tiers keep Ditto's signature
 *   black-on-citrus.
 * - `tertiary` carries the violet "promo" accent.
 * - `error` carries the red "critical" status.
 * - Non-Material semantics (info/success/warning/promo surfaces, borders,
 *   code colors…) remain available via [DittoSemanticColors] instead of being
 *   squeezed into a Material role.
 */
private fun dittoColorScheme(
    semantic: AnvilSemanticColors,
    primary: Color,
    onPrimary: Color,
    primaryContainer: Color,
    onPrimaryContainer: Color,
    secondary: Color,
    onSecondary: Color,
    secondaryContainer: Color,
    onSecondaryContainer: Color,
    tertiary: Color,
    onTertiary: Color,
    tertiaryContainer: Color,
    onTertiaryContainer: Color,
    error: Color,
    onError: Color,
    errorContainer: Color,
    onErrorContainer: Color,
    surfaceDim: Color,
    surfaceVariant: Color,
    surfaceContainerLowest: Color,
    surfaceContainerLow: Color,
    surfaceContainer: Color,
    surfaceContainerHigh: Color,
    surfaceContainerHighest: Color,
    surfaceBright: Color,
    outline: Color,
    outlineVariant: Color,
    inversePrimary: Color,
    dark: Boolean,
): ColorScheme {
    // darkColorScheme() and lightColorScheme() differ only in their default
    // values; every role is passed explicitly below, so a single factory is
    // sufficient. `dark` is kept on the signature to make caller intent clear.
    @Suppress("UNUSED_VARIABLE")
    val isDark = dark
    return lightColorScheme(
        primary = primary,
        onPrimary = onPrimary,
        primaryContainer = primaryContainer,
        onPrimaryContainer = onPrimaryContainer,
        secondary = secondary,
        onSecondary = onSecondary,
        secondaryContainer = secondaryContainer,
        onSecondaryContainer = onSecondaryContainer,
        tertiary = tertiary,
        onTertiary = onTertiary,
        tertiaryContainer = tertiaryContainer,
        onTertiaryContainer = onTertiaryContainer,
        error = error,
        onError = onError,
        errorContainer = errorContainer,
        onErrorContainer = onErrorContainer,
        background = semantic.background,
        onBackground = semantic.foregroundNormal,
        surface = semantic.surface,
        onSurface = semantic.foregroundNormal,
        surfaceVariant = surfaceVariant,
        onSurfaceVariant = semantic.foregroundSubtle,
        surfaceTint = primary,
        inverseSurface = semantic.inverse,
        inverseOnSurface = semantic.foregroundOnInverse,
        inversePrimary = inversePrimary,
        outline = outline,
        outlineVariant = outlineVariant,
        scrim = Color.Black,
        surfaceDim = surfaceDim,
        surfaceBright = surfaceBright,
        // "Fixed" roles (M3 2024 spec): anchored variants for prominent
        // containers. Derived from the container roles until design provides
        // dedicated values.
        primaryFixed = primaryContainer,
        primaryFixedDim = primaryContainer,
        onPrimaryFixed = onPrimaryContainer,
        onPrimaryFixedVariant = onPrimaryContainer,
        secondaryFixed = secondaryContainer,
        secondaryFixedDim = secondaryContainer,
        onSecondaryFixed = onSecondaryContainer,
        onSecondaryFixedVariant = onSecondaryContainer,
        tertiaryFixed = tertiaryContainer,
        tertiaryFixedDim = tertiaryContainer,
        onTertiaryFixed = onTertiaryContainer,
        onTertiaryFixedVariant = onTertiaryContainer,
        surfaceContainerLowest = surfaceContainerLowest,
        surfaceContainerLow = surfaceContainerLow,
        surfaceContainer = surfaceContainer,
        surfaceContainerHigh = surfaceContainerHigh,
        surfaceContainerHighest = surfaceContainerHighest,
    )
}

/** Material 3 [ColorScheme] for Anvil's light tier. */
fun anvilLightColorScheme(): ColorScheme = with(AnvilLightPalette) {
    val semantic = anvilSemanticColors(AnvilThemeTier.Light)
    dittoColorScheme(
        semantic = semantic,
        primary = semantic.fillBrandPrimary,
        onPrimary = semantic.foregroundOnBrandPrimary,
        primaryContainer = citrus400,
        onPrimaryContainer = neutral950,
        secondary = semantic.fillBrandSecondary,
        onSecondary = semantic.foregroundOnFill,
        secondaryContainer = neutral200,
        onSecondaryContainer = neutral950,
        // violet500 with black content is the promo pair for secondary fills,
        // but M3 onTertiary is white — violet600 keeps that ≥4.5:1.
        tertiary = violet600,
        onTertiary = semantic.foregroundOnFill,
        tertiaryContainer = semantic.fillPromoSecondary,
        onTertiaryContainer = violet900,
        error = semantic.fillCritical,
        onError = semantic.foregroundOnFill,
        errorContainer = semantic.fillCriticalSecondary,
        onErrorContainer = red900,
        surfaceDim = neutral200,
        surfaceVariant = neutral200,
        surfaceContainerLowest = white,
        surfaceContainerLow = neutral100,
        surfaceContainer = neutral100,
        surfaceContainerHigh = neutral200,
        surfaceContainerHighest = neutral200,
        surfaceBright = white,
        outline = neutral500,
        outlineVariant = neutral300,
        inversePrimary = citrus400,
        dark = false,
    )
}

/** Material 3 [ColorScheme] for Anvil's dark tier. */
fun anvilDarkColorScheme(): ColorScheme = with(AnvilDarkPalette) {
    val semantic = anvilSemanticColors(AnvilThemeTier.Dark)
    dittoColorScheme(
        semantic = semantic,
        primary = semantic.fillBrandPrimary,
        onPrimary = semantic.foregroundOnBrandPrimary,
        primaryContainer = citrus50,
        onPrimaryContainer = citrus500,
        secondary = semantic.fillBrandSecondary,
        onSecondary = semantic.foregroundOnFill,
        secondaryContainer = neutral300,
        onSecondaryContainer = neutral950,
        tertiary = semantic.fillPromo,
        onTertiary = semantic.foregroundOnFill,
        tertiaryContainer = violet50,
        onTertiaryContainer = violet700, // violet500-dark would be only ~3.5:1 here
        error = semantic.fillCritical,
        onError = semantic.foregroundOnFill,
        errorContainer = red50,
        onErrorContainer = red600, // red500-dark is only ~4.2:1 on red50-dark
        surfaceDim = neutral50,
        surfaceVariant = neutral300,
        surfaceContainerLowest = neutral50,
        surfaceContainerLow = neutral100,
        surfaceContainer = neutral200,
        surfaceContainerHigh = neutral300,
        surfaceContainerHighest = neutral400,
        surfaceBright = neutral300,
        outline = neutral500,
        outlineVariant = neutral300,
        // inversePrimary renders on inverseSurface (near-white in dark), so it
        // must be the dark, adult citrus — dark-tier citrus100, not the flipped
        // citrus800 (which is near-white in this tier).
        inversePrimary = citrus100,
        dark = true,
    )
}

/** Material 3 [ColorScheme] for Anvil's light high-contrast tier. */
fun anvilLightHighContrastColorScheme(): ColorScheme = with(AnvilLightHighContrastPalette) {
    val semantic = anvilSemanticColors(AnvilThemeTier.LightHighContrast)
    dittoColorScheme(
        semantic = semantic,
        primary = semantic.fillBrandPrimary,
        onPrimary = semantic.foregroundOnBrandPrimary,
        primaryContainer = citrus400,
        onPrimaryContainer = neutral950,
        secondary = semantic.fillBrandSecondary,
        onSecondary = semantic.foregroundOnFill,
        secondaryContainer = neutral200,
        onSecondaryContainer = neutral950,
        tertiary = violet600,
        onTertiary = semantic.foregroundOnFill,
        tertiaryContainer = semantic.fillPromoSecondary,
        onTertiaryContainer = violet900,
        error = semantic.fillCritical,
        onError = semantic.foregroundOnFill,
        errorContainer = semantic.fillCriticalSecondary,
        onErrorContainer = red900,
        surfaceDim = neutral200,
        surfaceVariant = neutral200,
        surfaceContainerLowest = white,
        surfaceContainerLow = neutral100,
        surfaceContainer = neutral100,
        surfaceContainerHigh = neutral200,
        surfaceContainerHighest = neutral200,
        surfaceBright = white,
        // HC tiers use opaque, strong borders (web: --border-normal: neutral-950).
        outline = neutral950,
        outlineVariant = neutral600,
        inversePrimary = citrus400,
        dark = false,
    )
}

/** Material 3 [ColorScheme] for Anvil's dark high-contrast tier. */
fun anvilDarkHighContrastColorScheme(): ColorScheme = with(AnvilDarkHighContrastPalette) {
    val semantic = anvilSemanticColors(AnvilThemeTier.DarkHighContrast)
    dittoColorScheme(
        semantic = semantic,
        primary = semantic.fillBrandPrimary,
        onPrimary = semantic.foregroundOnBrandPrimary,
        primaryContainer = citrus50,
        onPrimaryContainer = citrus500,
        secondary = semantic.fillBrandSecondary,
        // The dark-HC web tier flips on-fill to white, but brand-secondary here
        // is the near-white neutral-950 — use brand-content black to stay legible.
        onSecondary = semantic.foregroundOnBrandPrimary,
        secondaryContainer = neutral300,
        onSecondaryContainer = neutral950,
        tertiary = semantic.fillPromo,
        onTertiary = semantic.foregroundOnFill,
        tertiaryContainer = violet50,
        // dark-HC ramps compress the 500-700 steps together; violet800 jumps to
        // pale lilac, which sits at AA on the dark violet-50 container.
        onTertiaryContainer = violet800,
        error = semantic.fillCritical,
        // Same as onSecondary: dark-HC "on fill" is white but the filled roles
        // here are the HC palette's light steps — black content stays legible.
        onError = semantic.foregroundOnBrandPrimary,
        errorContainer = red50,
        onErrorContainer = red800, // dark-HC mid steps compress together; jump to the pale step
        surfaceDim = neutral50,
        surfaceVariant = neutral300,
        surfaceContainerLowest = neutral50,
        surfaceContainerLow = neutral100,
        surfaceContainer = neutral200,
        surfaceContainerHigh = neutral300,
        surfaceContainerHighest = neutral400,
        surfaceBright = neutral300,
        // HC tiers use opaque, strong borders (web: --border-normal: neutral-950).
        // The compressed dark-HC ramp has no mid-gray that reaches the 3:1 UI
        // minimum on black surfaces (neutral-700 is only 2.7:1), so the variant
        // steps down to the pale neutral-800 instead of a dead mid-gray.
        outline = neutral950,
        outlineVariant = neutral800,
        inversePrimary = citrus100,
        dark = true,
    )
}
