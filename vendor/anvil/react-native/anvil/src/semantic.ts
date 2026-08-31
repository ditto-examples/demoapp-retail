import { anvilDarkPalette, anvilLightPalette } from './tokens.generated.ts'

/** `--color-black-static`: true black in every tier. */
const blackStatic = '#000000'

interface WithAlpha {
  (hex: string, alpha: number): string
}

/** Appends an alpha channel to a 6-digit hex color (RN 8-digit hex syntax). */
const withAlpha: WithAlpha = (hex, alpha) =>
  `${hex}${Math.round(alpha * 255)
    .toString(16)
    .padStart(2, '0')
    .toUpperCase()}`

/**
 * Anvil's semantic color layer, ported from `src/theme.css` (light and dark
 * tiers — the React Native port ships 2 tiers; high-contrast tiers are a
 * future addition).
 *
 * Field names and values match the Android (`AnvilSemanticColors.kt`) and
 * Flutter (`anvil_semantic_colors.dart`) ports exactly.
 */
export interface AnvilSemanticColors {
  // Surfaces
  background: string
  surface: string
  surfaceHovered: string
  surfaceSecondary: string
  overlay: string
  overlayHovered: string
  inverse: string
  // Brand + control fills
  fillBrandPrimary: string
  fillBrandPrimaryHovered: string
  fillBrandSecondary: string
  fillBrandSecondaryHovered: string
  fillDisabled: string
  fillOpaque: string
  fillControlSelected: string
  // Status fills
  fillInfo: string
  fillInfoSecondary: string
  fillSuccess: string
  fillSuccessSecondary: string
  fillWarning: string
  fillWarningSecondary: string
  fillCritical: string
  fillCriticalSecondary: string
  fillPromo: string
  fillPromoSecondary: string
  fillPromoSecondaryHovered: string
  // Foregrounds
  foregroundNormal: string
  foregroundSubtle: string
  foregroundAccent: string
  foregroundWarning: string
  foregroundDisabled: string
  foregroundOnFill: string
  foregroundOnInverse: string
  foregroundOnBrandPrimary: string
  // Borders
  borderNormal: string
  borderStrong: string
  borderInfo: string
  borderSuccess: string
  borderWarning: string
  borderCritical: string
  borderPromo: string
  borderControlSelected: string
  // Focus / progress
  ring: string
  focusOutline: string
  progress: string
  progressRemaining: string
  // Code highlighting
  codeBackground: string
  codeForeground: string
  codeMuted: string
  codeKeyword: string
  codeLiteral: string
  codeString: string
  codeSelection: string
}

/** Anvil light theme semantic colors (`:root.light` in theme.css). */
export function lightAnvilColors(): AnvilSemanticColors {
  const p = anvilLightPalette
  return {
    background: p.neutral50,
    surface: p.white,
    surfaceHovered: withAlpha(p.neutral500, 0.02),
    surfaceSecondary: withAlpha(p.neutral500, 0.04),
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
    fillOpaque: withAlpha(p.neutral950, 0.03),
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

    borderNormal: withAlpha(p.neutral950, 0.12),
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
    progressRemaining: withAlpha(p.citrus700, 0.2),

    codeBackground: p.white,
    codeForeground: p.neutral950,
    codeMuted: p.neutral600,
    codeKeyword: p.citrus700,
    codeLiteral: p.sunset600,
    codeString: p.sky800,
    codeSelection: withAlpha(p.citrus500, 0.15),
  }
}

/** Anvil dark theme semantic colors (`:root.dark` in theme.css). */
export function darkAnvilColors(): AnvilSemanticColors {
  const p = anvilDarkPalette
  return {
    background: p.neutral100,
    surface: p.neutral200,
    surfaceHovered: withAlpha(p.neutral500, 0.07),
    surfaceSecondary: withAlpha(p.neutral500, 0.15),
    overlay: p.neutral200,
    overlayHovered: p.neutral100,
    inverse: p.neutral950,

    fillBrandPrimary: p.citrus600,
    fillBrandPrimaryHovered: p.citrus700,
    fillBrandSecondary: p.neutral950,
    fillBrandSecondaryHovered: p.neutral950,
    fillDisabled: p.neutral600,
    fillOpaque: withAlpha(p.neutral950, 0.03),
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

    borderNormal: withAlpha(p.neutral950, 0.25),
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
    progressRemaining: withAlpha(p.citrus700, 0.2),

    codeBackground: p.neutral200,
    codeForeground: p.neutral950,
    codeMuted: p.neutral700,
    codeKeyword: p.citrus700,
    codeLiteral: p.sunset600,
    codeString: p.sky800,
    codeSelection: withAlpha(p.citrus500, 0.15),
  }
}

/** Resolves semantic colors for light/dark mode. */
export function anvilSemanticColors(
  tier: 'light' | 'dark',
): AnvilSemanticColors {
  return tier === 'dark' ? darkAnvilColors() : lightAnvilColors()
}
