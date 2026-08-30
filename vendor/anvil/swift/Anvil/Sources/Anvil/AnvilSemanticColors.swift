import SwiftUI

/// `--color-black-static`: true black in every tier.
private let blackStatic = Color(rgb: 0x000000)

/// Anvil's semantic color layer, ported from `src/theme.css`.
///
/// These are the brand-meaningful colors (brand fills, info/success/warning/
/// critical/promo surfaces, foregrounds, borders, focus rings) built on top of
/// the primitive palettes. The layer is exposed to apps because brand semantics
/// such as "success surface" or "warning border" have no SwiftUI equivalent.
///
/// All values are deliberately faithful to the web CSS and match the Android
/// (`AnvilSemanticColors.kt`), Flutter (`anvil_semantic_colors.dart`) and
/// React Native (`semantic.ts`) ports field-for-field. Note that in the dark
/// tiers Anvil flips `black`/`white` and reverses the ramps, exactly as the
/// CSS does.
public struct AnvilSemanticColors: Sendable, Equatable {
    // Surfaces
    public let background: Color
    public let surface: Color
    public let surfaceHovered: Color
    public let surfaceSecondary: Color
    public let overlay: Color
    public let overlayHovered: Color
    public let inverse: Color
    // Brand + control fills
    public let fillBrandPrimary: Color
    public let fillBrandPrimaryHovered: Color
    public let fillBrandSecondary: Color
    public let fillBrandSecondaryHovered: Color
    public let fillDisabled: Color
    public let fillOpaque: Color
    public let fillControlSelected: Color
    // Status fills
    public let fillInfo: Color
    public let fillInfoSecondary: Color
    public let fillSuccess: Color
    public let fillSuccessSecondary: Color
    public let fillWarning: Color
    public let fillWarningSecondary: Color
    public let fillCritical: Color
    public let fillCriticalSecondary: Color
    public let fillPromo: Color
    public let fillPromoSecondary: Color
    public let fillPromoSecondaryHovered: Color
    // Foregrounds
    public let foregroundNormal: Color
    public let foregroundSubtle: Color
    public let foregroundAccent: Color
    public let foregroundWarning: Color
    public let foregroundDisabled: Color
    public let foregroundOnFill: Color
    public let foregroundOnInverse: Color
    public let foregroundOnBrandPrimary: Color
    // Borders
    public let borderNormal: Color
    public let borderStrong: Color
    public let borderInfo: Color
    public let borderSuccess: Color
    public let borderWarning: Color
    public let borderCritical: Color
    public let borderPromo: Color
    public let borderControlSelected: Color
    // Focus / progress
    public let ring: Color
    public let focusOutline: Color
    public let progress: Color
    public let progressRemaining: Color
    // Code highlighting
    public let codeBackground: Color
    public let codeForeground: Color
    public let codeMuted: Color
    public let codeKeyword: Color
    public let codeLiteral: Color
    public let codeString: Color
    public let codeSelection: Color
}

/// Anvil light theme semantic colors (`:root.light` in theme.css).
public func lightAnvilColors() -> AnvilSemanticColors {
    let p = AnvilLightPalette.self
    return AnvilSemanticColors(
        background: p.neutral50,
        surface: p.white,
        surfaceHovered: p.neutral500.withAlpha(0.02),
        surfaceSecondary: p.neutral500.withAlpha(0.04),
        overlay: p.white,
        overlayHovered: p.neutral50,
        inverse: p.neutral950,

        // Web light tier: brand primary is black-on-white (readability);
        // citrus brand fills remain in the dark/high-contrast tiers.
        fillBrandPrimary: p.neutral950,
        fillBrandPrimaryHovered: p.neutral950,
        fillBrandSecondary: p.neutral950,
        fillBrandSecondaryHovered: p.neutral950,
        fillDisabled: p.neutral300,
        fillOpaque: p.neutral950.withAlpha(0.03),
        fillControlSelected: p.black,

        fillInfo: p.sky500,
        fillInfoSecondary: p.sky50,
        fillSuccess: p.emerald600,
        fillSuccessSecondary: p.emerald100,
        fillWarning: p.orange600,
        fillWarningSecondary: p.orange100,
        fillCritical: p.red600,
        fillCriticalSecondary: p.red100,
        fillPromo: p.violet500,
        fillPromoSecondary: p.violet100,
        fillPromoSecondaryHovered: p.violet200,

        foregroundNormal: p.neutral950,
        foregroundSubtle: p.neutral600,
        foregroundAccent: p.citrus700,
        foregroundWarning: p.orange600,
        foregroundDisabled: p.neutral500,
        foregroundOnFill: p.white,
        foregroundOnInverse: p.white,
        foregroundOnBrandPrimary: p.white,

        borderNormal: p.neutral950.withAlpha(0.12),
        borderStrong: p.neutral950,
        borderInfo: p.sky500,
        borderSuccess: p.emerald600,
        borderWarning: p.orange600,
        borderCritical: p.red600,
        borderPromo: p.violet500,
        borderControlSelected: p.black,

        ring: p.citrus700,
        focusOutline: p.citrus700,
        progress: p.citrus700,
        progressRemaining: p.citrus700.withAlpha(0.20),

        codeBackground: p.white,
        codeForeground: p.neutral950,
        codeMuted: p.neutral600,
        codeKeyword: p.citrus700,
        codeLiteral: p.sunset600,
        codeString: p.sky800,
        codeSelection: p.citrus500.withAlpha(0.15)
    )
}

/// Anvil dark theme semantic colors (`:root.dark` in theme.css).
public func darkAnvilColors() -> AnvilSemanticColors {
    let p = AnvilDarkPalette.self
    return AnvilSemanticColors(
        background: p.neutral100,
        surface: p.neutral200,
        surfaceHovered: p.neutral500.withAlpha(0.07),
        surfaceSecondary: p.neutral500.withAlpha(0.15),
        overlay: p.neutral200,
        overlayHovered: p.neutral100,
        inverse: p.neutral950,

        fillBrandPrimary: p.citrus600,
        fillBrandPrimaryHovered: p.citrus700,
        fillBrandSecondary: p.neutral950,
        fillBrandSecondaryHovered: p.neutral950,
        fillDisabled: p.neutral600,
        fillOpaque: p.neutral950.withAlpha(0.03),
        fillControlSelected: p.primary,

        fillInfo: p.sky600,
        fillInfoSecondary: p.sky50,
        fillSuccess: p.emerald600,
        fillSuccessSecondary: p.emerald50,
        fillWarning: p.orange600,
        fillWarningSecondary: p.orange50,
        fillCritical: p.red600,
        fillCriticalSecondary: p.red50,
        fillPromo: p.violet600,
        fillPromoSecondary: p.violet50,
        fillPromoSecondaryHovered: p.violet100,

        foregroundNormal: p.neutral950,
        foregroundSubtle: p.neutral700,
        foregroundAccent: p.citrus600,
        foregroundWarning: p.orange600,
        foregroundDisabled: p.neutral500,
        // `white`/`black` are flipped in the dark tier, matching the CSS.
        foregroundOnFill: p.white,
        foregroundOnInverse: p.white,
        foregroundOnBrandPrimary: blackStatic,

        borderNormal: p.neutral950.withAlpha(0.25),
        borderStrong: p.neutral950,
        borderInfo: p.sky500,
        borderSuccess: p.emerald600,
        borderWarning: p.orange600,
        borderCritical: p.red600,
        borderPromo: p.violet500,
        borderControlSelected: p.primary,

        ring: p.citrus700,
        focusOutline: p.citrus600,
        // The bare `:root` block of theme.css pins --progress to citrus-700 for
        // every tier (the dark block does not override it).
        progress: p.citrus700,
        progressRemaining: p.citrus700.withAlpha(0.20),

        codeBackground: p.neutral200,
        codeForeground: p.neutral950,
        codeMuted: p.neutral700,
        codeKeyword: p.citrus700,
        codeLiteral: p.sunset600,
        codeString: p.sky800,
        codeSelection: p.citrus500.withAlpha(0.15)
    )
}

/// Anvil light high-contrast semantic colors (`:root.light-high-contrast`).
public func lightHighContrastAnvilColors() -> AnvilSemanticColors {
    let p = AnvilLightHighContrastPalette.self
    return AnvilSemanticColors(
        background: p.neutral50,
        surface: p.white,
        surfaceHovered: p.neutral500.withAlpha(0.02),
        surfaceSecondary: p.neutral500.withAlpha(0.04),
        overlay: p.white,
        overlayHovered: p.neutral50,
        inverse: p.neutral950,

        fillBrandPrimary: p.citrus800,
        fillBrandPrimaryHovered: p.citrus900,
        fillBrandSecondary: p.neutral950,
        fillBrandSecondaryHovered: p.neutral950,
        fillDisabled: p.neutral300.withAlpha(0.60),
        fillOpaque: p.neutral950.withAlpha(0.03),
        fillControlSelected: p.black,

        fillInfo: p.sky500,
        fillInfoSecondary: p.sky50,
        fillSuccess: p.emerald600,
        fillSuccessSecondary: p.emerald100,
        fillWarning: p.orange600,
        fillWarningSecondary: p.orange100,
        fillCritical: p.red800,
        fillCriticalSecondary: p.red100,
        fillPromo: p.violet500,
        fillPromoSecondary: p.violet100,
        fillPromoSecondaryHovered: p.violet200,

        foregroundNormal: p.black,
        foregroundSubtle: p.neutral800,
        foregroundAccent: p.citrus700,
        foregroundWarning: p.orange600,
        foregroundDisabled: p.neutral500,
        foregroundOnFill: p.white,
        foregroundOnInverse: p.white,
        foregroundOnBrandPrimary: blackStatic,

        borderNormal: p.neutral950,
        borderStrong: p.neutral950,
        borderInfo: p.sky500,
        borderSuccess: p.emerald600,
        borderWarning: p.orange600,
        borderCritical: p.red600,
        borderPromo: p.violet500,
        borderControlSelected: p.black,

        ring: p.citrus700,
        focusOutline: p.citrus700,
        progress: p.citrus800,
        progressRemaining: p.citrus800.withAlpha(0.20),

        codeBackground: p.white,
        codeForeground: p.black,
        codeMuted: p.neutral800,
        codeKeyword: p.citrus900,
        codeLiteral: p.sunset800,
        codeString: p.sky950,
        codeSelection: p.citrus500.withAlpha(0.15)
    )
}

/// Anvil dark high-contrast semantic colors (`:root.dark-high-contrast`).
///
/// Cascade note: the web applies `dark-high-contrast` as a *single* class —
/// the `:root.dark` override block does NOT apply. So this tier = `@theme`
/// defaults + the bare `:root` overrides + the dark-high-contrast block.
public func darkHighContrastAnvilColors() -> AnvilSemanticColors {
    let p = AnvilDarkHighContrastPalette.self
    return AnvilSemanticColors(
        background: p.neutral50,
        surface: p.white, // flipped in the dark tier — resolves to black
        surfaceHovered: p.neutral500.withAlpha(0.02),
        surfaceSecondary: p.neutral500.withAlpha(0.04),
        overlay: p.white, // flipped — black
        overlayHovered: p.neutral50,
        inverse: p.neutral950,

        fillBrandPrimary: p.citrus800,
        fillBrandPrimaryHovered: p.citrus900,
        fillBrandSecondary: p.neutral950,
        fillBrandSecondaryHovered: p.neutral950,
        fillDisabled: p.black, // per CSS --fill-disabled: var(--color-black)
        fillOpaque: p.neutral950.withAlpha(0.03),
        fillControlSelected: p.primary,

        fillInfo: p.sky500,
        fillInfoSecondary: p.sky50,
        fillSuccess: p.emerald600,
        fillSuccessSecondary: p.emerald50,
        fillWarning: p.orange600,
        fillWarningSecondary: p.orange50,
        fillCritical: p.red800,
        fillCriticalSecondary: p.red50,
        fillPromo: p.violet500,
        fillPromoSecondary: p.violet50,
        fillPromoSecondaryHovered: p.violet100,

        foregroundNormal: p.black, // flipped — resolves to white
        foregroundSubtle: p.neutral800,
        foregroundAccent: p.citrus800,
        foregroundWarning: p.orange600,
        foregroundDisabled: p.neutral500,
        foregroundOnFill: p.black, // flipped — resolves to white
        foregroundOnInverse: p.white, // flipped — resolves to black
        foregroundOnBrandPrimary: blackStatic,

        borderNormal: p.neutral950,
        borderStrong: p.neutral950,
        borderInfo: p.sky800,
        borderSuccess: p.emerald800,
        borderWarning: p.orange800,
        borderCritical: p.red800,
        borderPromo: p.violet800,
        borderControlSelected: p.primary,

        ring: p.citrus700,
        focusOutline: p.citrus700,
        progress: p.citrus700,
        progressRemaining: p.citrus700.withAlpha(0.20),

        codeBackground: p.white, // flipped — black
        codeForeground: p.black,
        codeMuted: p.neutral800,
        codeKeyword: p.citrus900,
        codeLiteral: p.sunset800,
        codeString: p.sky950,
        codeSelection: p.citrus500.withAlpha(0.15)
    )
}

/// Resolves semantic colors for a given [AnvilThemeTier].
public func anvilSemanticColors(tier: AnvilThemeTier) -> AnvilSemanticColors {
    switch tier {
    case .light: return lightAnvilColors()
    case .dark: return darkAnvilColors()
    case .lightHighContrast: return lightHighContrastAnvilColors()
    case .darkHighContrast: return darkHighContrastAnvilColors()
    }
}
