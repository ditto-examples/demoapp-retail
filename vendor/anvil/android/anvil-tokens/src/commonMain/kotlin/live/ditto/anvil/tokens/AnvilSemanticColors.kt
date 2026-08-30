package live.ditto.anvil.tokens

import androidx.compose.ui.graphics.Color

/** `--color-black-static`: true black in every tier. */
private val BlackStatic = Color(0xFF000000)

/**
 * Anvil's semantic color layer, ported from `src/theme.css`.
 *
 * These are the brand-meaningful colors (brand fills, info/success/warning/
 * critical/promo surfaces, foregrounds, borders, focus rings) built on top of
 * the primitive palettes ([AnvilLightPalette], [AnvilDarkPalette] and the
 * high-contrast variants). The Material `ColorScheme` in the theme modules is
 * derived from this layer, and the layer itself is exposed to apps because
 * brand semantics such as "success surface" or "warning border" have no
 * Material role.
 *
 * All values are deliberately faithful to the web CSS. The light tier uses a
 * black brand fill with white foreground (readability); Anvil's signature
 * black-on-citrus brand fill remains in the dark and high-contrast tiers
 * (accessed via [foregroundOnBrandPrimary]). Note that in the dark tiers Anvil
 * flips `black`/`white` and reverses the ramps, exactly as the CSS does.
 */
data class AnvilSemanticColors(
    // Surfaces
    val background: Color,
    val surface: Color,
    val surfaceHovered: Color,
    val surfaceSecondary: Color,
    val overlay: Color,
    val overlayHovered: Color,
    val inverse: Color,
    // Brand + control fills
    val fillBrandPrimary: Color,
    val fillBrandPrimaryHovered: Color,
    val fillBrandSecondary: Color,
    val fillBrandSecondaryHovered: Color,
    val fillDisabled: Color,
    val fillOpaque: Color,
    val fillControlSelected: Color,
    // Status fills
    val fillInfo: Color,
    val fillInfoSecondary: Color,
    val fillSuccess: Color,
    val fillSuccessSecondary: Color,
    val fillWarning: Color,
    val fillWarningSecondary: Color,
    val fillCritical: Color,
    val fillCriticalSecondary: Color,
    val fillPromo: Color,
    val fillPromoSecondary: Color,
    val fillPromoSecondaryHovered: Color,
    // Foregrounds
    val foregroundNormal: Color,
    val foregroundSubtle: Color,
    val foregroundAccent: Color,
    val foregroundWarning: Color,
    val foregroundDisabled: Color,
    val foregroundOnFill: Color,
    val foregroundOnInverse: Color,
    val foregroundOnBrandPrimary: Color,
    // Borders
    val borderNormal: Color,
    val borderStrong: Color,
    val borderInfo: Color,
    val borderSuccess: Color,
    val borderWarning: Color,
    val borderCritical: Color,
    val borderPromo: Color,
    val borderControlSelected: Color,
    // Focus / progress
    val ring: Color,
    val focusOutline: Color,
    val progress: Color,
    val progressRemaining: Color,
    // Code highlighting
    val codeBackground: Color,
    val codeForeground: Color,
    val codeMuted: Color,
    val codeKeyword: Color,
    val codeLiteral: Color,
    val codeString: Color,
    val codeSelection: Color,
)

/** Anvil light theme semantic colors (`:root.light` in theme.css). */
fun lightAnvilColors(): AnvilSemanticColors = with(AnvilLightPalette) {
    AnvilSemanticColors(
        background = neutral50,
        surface = white,
        surfaceHovered = neutral500.copy(alpha = 0.02f),
        surfaceSecondary = neutral500.copy(alpha = 0.04f),
        overlay = white,
        overlayHovered = neutral50,
        inverse = neutral950,

        // Web light tier: brand primary is black-on-white (readability);
        // citrus brand fills remain in the dark/high-contrast tiers.
        fillBrandPrimary = neutral950,
        fillBrandPrimaryHovered = neutral950,
        fillBrandSecondary = neutral950,
        fillBrandSecondaryHovered = neutral950,
        fillDisabled = neutral300,
        fillOpaque = neutral950.copy(alpha = 0.03f),
        fillControlSelected = black,

        fillInfo = sky500,
        fillInfoSecondary = sky50,
        fillSuccess = emerald600,
        fillSuccessSecondary = emerald100,
        fillWarning = orange600,
        fillWarningSecondary = orange100,
        fillCritical = red600,
        fillCriticalSecondary = red100,
        fillPromo = violet500,
        fillPromoSecondary = violet100,
        fillPromoSecondaryHovered = violet200,

        foregroundNormal = neutral950,
        foregroundSubtle = neutral600,
        foregroundAccent = citrus700,
        foregroundWarning = orange600,
        foregroundDisabled = neutral500,
        foregroundOnFill = white,
        foregroundOnInverse = white,
        foregroundOnBrandPrimary = white,

        borderNormal = neutral950.copy(alpha = 0.12f),
        borderStrong = neutral950,
        borderInfo = sky500,
        borderSuccess = emerald600,
        borderWarning = orange600,
        borderCritical = red600,
        borderPromo = violet500,
        borderControlSelected = black,

        ring = citrus700,
        focusOutline = citrus700,
        progress = citrus700,
        progressRemaining = citrus700.copy(alpha = 0.20f),

        codeBackground = white,
        codeForeground = neutral950,
        codeMuted = neutral600,
        codeKeyword = citrus700,
        codeLiteral = sunset600,
        codeString = sky800,
        codeSelection = citrus500.copy(alpha = 0.15f),
    )
}

/** Anvil dark theme semantic colors (`:root.dark` in theme.css). */
fun darkAnvilColors(): AnvilSemanticColors = with(AnvilDarkPalette) {
    AnvilSemanticColors(
        background = neutral100,
        surface = neutral200,
        surfaceHovered = neutral500.copy(alpha = 0.07f),
        surfaceSecondary = neutral500.copy(alpha = 0.15f),
        overlay = neutral200,
        overlayHovered = neutral100,
        inverse = neutral950,

        fillBrandPrimary = citrus600,
        fillBrandPrimaryHovered = citrus700,
        fillBrandSecondary = neutral950,
        fillBrandSecondaryHovered = neutral950,
        fillDisabled = neutral600,
        fillOpaque = neutral950.copy(alpha = 0.03f),
        fillControlSelected = primary,

        fillInfo = sky600,
        fillInfoSecondary = sky50,
        fillSuccess = emerald600,
        fillSuccessSecondary = emerald50,
        fillWarning = orange600,
        fillWarningSecondary = orange50,
        fillCritical = red600,
        fillCriticalSecondary = red50,
        fillPromo = violet600,
        fillPromoSecondary = violet50,
        fillPromoSecondaryHovered = violet100,

        foregroundNormal = neutral950,
        foregroundSubtle = neutral700,
        foregroundAccent = citrus600,
        foregroundWarning = orange600,
        foregroundDisabled = neutral500,
        // `white`/`black` are flipped in the dark tier, matching the CSS.
        foregroundOnFill = white,
        foregroundOnInverse = white,
        foregroundOnBrandPrimary = BlackStatic,

        borderNormal = neutral950.copy(alpha = 0.25f),
        borderStrong = neutral950,
        borderInfo = sky500,
        borderSuccess = emerald600,
        borderWarning = orange600,
        borderCritical = red600,
        borderPromo = violet500,
        borderControlSelected = primary,

        ring = citrus700,
        focusOutline = citrus600,
        // The bare `:root` block of theme.css pins --progress to citrus-700 for
        // every tier (the dark block does not override it).
        progress = citrus700,
        progressRemaining = citrus700.copy(alpha = 0.20f),

        codeBackground = neutral200,
        codeForeground = neutral950,
        codeMuted = neutral700,
        codeKeyword = citrus700,
        codeLiteral = sunset600,
        codeString = sky800,
        codeSelection = citrus500.copy(alpha = 0.15f),
    )
}

/** Anvil light high-contrast semantic colors (`:root.light-high-contrast`). */
fun lightHighContrastAnvilColors(): AnvilSemanticColors = with(AnvilLightHighContrastPalette) {
    AnvilSemanticColors(
        background = neutral50,
        surface = white,
        surfaceHovered = neutral500.copy(alpha = 0.02f),
        surfaceSecondary = neutral500.copy(alpha = 0.04f),
        overlay = white,
        overlayHovered = neutral50,
        inverse = neutral950,

        fillBrandPrimary = citrus800,
        fillBrandPrimaryHovered = citrus900,
        fillBrandSecondary = neutral950,
        fillBrandSecondaryHovered = neutral950,
        fillDisabled = neutral300.copy(alpha = 0.60f),
        fillOpaque = neutral950.copy(alpha = 0.03f),
        fillControlSelected = black,

        fillInfo = sky500,
        fillInfoSecondary = sky50,
        fillSuccess = emerald600,
        fillSuccessSecondary = emerald100,
        fillWarning = orange600,
        fillWarningSecondary = orange100,
        fillCritical = red800,
        fillCriticalSecondary = red100,
        fillPromo = violet500,
        fillPromoSecondary = violet100,
        fillPromoSecondaryHovered = violet200,

        foregroundNormal = black,
        foregroundSubtle = neutral800,
        foregroundAccent = citrus700,
        foregroundWarning = orange600,
        foregroundDisabled = neutral500,
        foregroundOnFill = white,
        foregroundOnInverse = white,
        foregroundOnBrandPrimary = BlackStatic,

        borderNormal = neutral950,
        borderStrong = neutral950,
        borderInfo = sky500,
        borderSuccess = emerald600,
        borderWarning = orange600,
        borderCritical = red600,
        borderPromo = violet500,
        borderControlSelected = black,

        ring = citrus700,
        focusOutline = citrus700,
        progress = citrus800,
        progressRemaining = citrus800.copy(alpha = 0.20f),

        codeBackground = white,
        codeForeground = black,
        codeMuted = neutral800,
        codeKeyword = citrus900,
        codeLiteral = sunset800,
        codeString = sky950,
        codeSelection = citrus500.copy(alpha = 0.15f),
    )
}

/**
 * Anvil dark high-contrast semantic colors (`:root.dark-high-contrast`).
 *
 * Cascade note: the web applies `dark-high-contrast` as a *single* class —
 * the `:root.dark` override block does NOT apply. So this tier = `@theme`
 * defaults + the bare `:root` overrides (shadows, progress, code) + the
 * dark-high-contrast block. Notably: surfaces stay at the dark-HC defaults
 * (white→black flip, 2%/4% hover alpha), and `fillInfo`/`fillPromo` keep the
 * default 500 steps.
 */
fun darkHighContrastAnvilColors(): AnvilSemanticColors = with(AnvilDarkHighContrastPalette) {
    AnvilSemanticColors(
        background = neutral50,
        surface = white, // flipped in the dark tier — resolves to black
        surfaceHovered = neutral500.copy(alpha = 0.02f),
        surfaceSecondary = neutral500.copy(alpha = 0.04f),
        overlay = white, // flipped — black
        overlayHovered = neutral50,
        inverse = neutral950,

        fillBrandPrimary = citrus800,
        fillBrandPrimaryHovered = citrus900,
        fillBrandSecondary = neutral950,
        fillBrandSecondaryHovered = neutral950,
        fillDisabled = black, // per CSS --fill-disabled: var(--color-black)
        fillOpaque = neutral950.copy(alpha = 0.03f),
        fillControlSelected = primary,

        fillInfo = sky500,
        fillInfoSecondary = sky50,
        fillSuccess = emerald600,
        fillSuccessSecondary = emerald50,
        fillWarning = orange600,
        fillWarningSecondary = orange50,
        fillCritical = red800,
        fillCriticalSecondary = red50,
        fillPromo = violet500,
        fillPromoSecondary = violet50,
        fillPromoSecondaryHovered = violet100,

        foregroundNormal = black, // flipped in the dark tier — resolves to white
        foregroundSubtle = neutral800,
        foregroundAccent = citrus800,
        foregroundWarning = orange600,
        foregroundDisabled = neutral500,
        foregroundOnFill = black, // flipped — resolves to white
        foregroundOnInverse = white, // flipped — resolves to black
        foregroundOnBrandPrimary = BlackStatic,

        borderNormal = neutral950,
        borderStrong = neutral950,
        borderInfo = sky800,
        borderSuccess = emerald800,
        borderWarning = orange800,
        borderCritical = red800,
        borderPromo = violet800,
        borderControlSelected = primary,

        ring = citrus700,
        focusOutline = citrus700,
        progress = citrus700,
        progressRemaining = citrus700.copy(alpha = 0.20f),

        codeBackground = white, // = --background-surface, flipped — black
        codeForeground = black,
        codeMuted = neutral800,
        codeKeyword = citrus900,
        codeLiteral = sunset800,
        codeString = sky950,
        codeSelection = citrus500.copy(alpha = 0.15f),
    )
}

/** Resolves semantic colors for a given [AnvilThemeTier]. */
fun anvilSemanticColors(tier: AnvilThemeTier): AnvilSemanticColors =
    when (tier) {
        AnvilThemeTier.Light -> lightAnvilColors()
        AnvilThemeTier.Dark -> darkAnvilColors()
        AnvilThemeTier.LightHighContrast -> lightHighContrastAnvilColors()
        AnvilThemeTier.DarkHighContrast -> darkHighContrastAnvilColors()
    }
