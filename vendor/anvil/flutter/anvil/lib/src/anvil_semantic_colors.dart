import 'package:flutter/material.dart';

import 'anvil_palette.dart';

/// `--color-black-static`: true black in every tier.
const Color _blackStatic = Color(0xFF000000);

/// Anvil's semantic color layer, ported from `src/theme.css`.
///
/// These are the brand-meaningful colors (brand fills, info/success/warning/
/// critical/promo surfaces, foregrounds, borders, focus rings) built on top of
/// the primitive palettes ([AnvilLightPalette], [AnvilDarkPalette] and the
/// high-contrast variants). The Material [ColorScheme] in [dittoColorSchemes]
/// is derived from this layer, and the layer itself is exposed to apps because
/// brand semantics such as "success surface" or "warning border" have no
/// Material role.
///
/// All values are deliberately faithful to the web CSS. The light tier uses a
/// black brand fill with white foreground (readability); Anvil's signature
/// black-on-citrus brand fill remains in the dark and high-contrast tiers
/// (accessed via [foregroundOnBrandPrimary]). Note that in the dark tiers Anvil
/// flips `black`/`white` and reverses the ramps, exactly as the CSS does.
@immutable
class AnvilSemanticColors extends ThemeExtension<AnvilSemanticColors> {
  const AnvilSemanticColors({
    // Surfaces
    required this.background,
    required this.surface,
    required this.surfaceHovered,
    required this.surfaceSecondary,
    required this.overlay,
    required this.overlayHovered,
    required this.inverse,
    // Brand + control fills
    required this.fillBrandPrimary,
    required this.fillBrandPrimaryHovered,
    required this.fillBrandSecondary,
    required this.fillBrandSecondaryHovered,
    required this.fillDisabled,
    required this.fillOpaque,
    required this.fillControlSelected,
    // Status fills
    required this.fillInfo,
    required this.fillInfoSecondary,
    required this.fillSuccess,
    required this.fillSuccessSecondary,
    required this.fillWarning,
    required this.fillWarningSecondary,
    required this.fillCritical,
    required this.fillCriticalSecondary,
    required this.fillPromo,
    required this.fillPromoSecondary,
    required this.fillPromoSecondaryHovered,
    // Foregrounds
    required this.foregroundNormal,
    required this.foregroundSubtle,
    required this.foregroundAccent,
    required this.foregroundWarning,
    required this.foregroundDisabled,
    required this.foregroundOnFill,
    required this.foregroundOnInverse,
    required this.foregroundOnBrandPrimary,
    // Borders
    required this.borderNormal,
    required this.borderStrong,
    required this.borderInfo,
    required this.borderSuccess,
    required this.borderWarning,
    required this.borderCritical,
    required this.borderPromo,
    required this.borderControlSelected,
    // Focus / progress
    required this.ring,
    required this.focusOutline,
    required this.progress,
    required this.progressRemaining,
    // Code highlighting
    required this.codeBackground,
    required this.codeForeground,
    required this.codeMuted,
    required this.codeKeyword,
    required this.codeLiteral,
    required this.codeString,
    required this.codeSelection,
  });

  // Surfaces
  final Color background;
  final Color surface;
  final Color surfaceHovered;
  final Color surfaceSecondary;
  final Color overlay;
  final Color overlayHovered;
  final Color inverse;
  // Brand + control fills
  final Color fillBrandPrimary;
  final Color fillBrandPrimaryHovered;
  final Color fillBrandSecondary;
  final Color fillBrandSecondaryHovered;
  final Color fillDisabled;
  final Color fillOpaque;
  final Color fillControlSelected;
  // Status fills
  final Color fillInfo;
  final Color fillInfoSecondary;
  final Color fillSuccess;
  final Color fillSuccessSecondary;
  final Color fillWarning;
  final Color fillWarningSecondary;
  final Color fillCritical;
  final Color fillCriticalSecondary;
  final Color fillPromo;
  final Color fillPromoSecondary;
  final Color fillPromoSecondaryHovered;
  // Foregrounds
  final Color foregroundNormal;
  final Color foregroundSubtle;
  final Color foregroundAccent;
  final Color foregroundWarning;
  final Color foregroundDisabled;
  final Color foregroundOnFill;
  final Color foregroundOnInverse;
  final Color foregroundOnBrandPrimary;
  // Borders
  final Color borderNormal;
  final Color borderStrong;
  final Color borderInfo;
  final Color borderSuccess;
  final Color borderWarning;
  final Color borderCritical;
  final Color borderPromo;
  final Color borderControlSelected;
  // Focus / progress
  final Color ring;
  final Color focusOutline;
  final Color progress;
  final Color progressRemaining;
  // Code highlighting
  final Color codeBackground;
  final Color codeForeground;
  final Color codeMuted;
  final Color codeKeyword;
  final Color codeLiteral;
  final Color codeString;
  final Color codeSelection;

  @override
  AnvilSemanticColors copyWith() => this; // Tier swaps are discrete, never partial.

  @override
  AnvilSemanticColors lerp(AnvilSemanticColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t) ?? b;
    return AnvilSemanticColors(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceHovered: l(surfaceHovered, other.surfaceHovered),
      surfaceSecondary: l(surfaceSecondary, other.surfaceSecondary),
      overlay: l(overlay, other.overlay),
      overlayHovered: l(overlayHovered, other.overlayHovered),
      inverse: l(inverse, other.inverse),
      fillBrandPrimary: l(fillBrandPrimary, other.fillBrandPrimary),
      fillBrandPrimaryHovered: l(
        fillBrandPrimaryHovered,
        other.fillBrandPrimaryHovered,
      ),
      fillBrandSecondary: l(fillBrandSecondary, other.fillBrandSecondary),
      fillBrandSecondaryHovered: l(
        fillBrandSecondaryHovered,
        other.fillBrandSecondaryHovered,
      ),
      fillDisabled: l(fillDisabled, other.fillDisabled),
      fillOpaque: l(fillOpaque, other.fillOpaque),
      fillControlSelected: l(fillControlSelected, other.fillControlSelected),
      fillInfo: l(fillInfo, other.fillInfo),
      fillInfoSecondary: l(fillInfoSecondary, other.fillInfoSecondary),
      fillSuccess: l(fillSuccess, other.fillSuccess),
      fillSuccessSecondary: l(fillSuccessSecondary, other.fillSuccessSecondary),
      fillWarning: l(fillWarning, other.fillWarning),
      fillWarningSecondary: l(fillWarningSecondary, other.fillWarningSecondary),
      fillCritical: l(fillCritical, other.fillCritical),
      fillCriticalSecondary: l(
        fillCriticalSecondary,
        other.fillCriticalSecondary,
      ),
      fillPromo: l(fillPromo, other.fillPromo),
      fillPromoSecondary: l(fillPromoSecondary, other.fillPromoSecondary),
      fillPromoSecondaryHovered: l(
        fillPromoSecondaryHovered,
        other.fillPromoSecondaryHovered,
      ),
      foregroundNormal: l(foregroundNormal, other.foregroundNormal),
      foregroundSubtle: l(foregroundSubtle, other.foregroundSubtle),
      foregroundAccent: l(foregroundAccent, other.foregroundAccent),
      foregroundWarning: l(foregroundWarning, other.foregroundWarning),
      foregroundDisabled: l(foregroundDisabled, other.foregroundDisabled),
      foregroundOnFill: l(foregroundOnFill, other.foregroundOnFill),
      foregroundOnInverse: l(foregroundOnInverse, other.foregroundOnInverse),
      foregroundOnBrandPrimary: l(
        foregroundOnBrandPrimary,
        other.foregroundOnBrandPrimary,
      ),
      borderNormal: l(borderNormal, other.borderNormal),
      borderStrong: l(borderStrong, other.borderStrong),
      borderInfo: l(borderInfo, other.borderInfo),
      borderSuccess: l(borderSuccess, other.borderSuccess),
      borderWarning: l(borderWarning, other.borderWarning),
      borderCritical: l(borderCritical, other.borderCritical),
      borderPromo: l(borderPromo, other.borderPromo),
      borderControlSelected: l(
        borderControlSelected,
        other.borderControlSelected,
      ),
      ring: l(ring, other.ring),
      focusOutline: l(focusOutline, other.focusOutline),
      progress: l(progress, other.progress),
      progressRemaining: l(progressRemaining, other.progressRemaining),
      codeBackground: l(codeBackground, other.codeBackground),
      codeForeground: l(codeForeground, other.codeForeground),
      codeMuted: l(codeMuted, other.codeMuted),
      codeKeyword: l(codeKeyword, other.codeKeyword),
      codeLiteral: l(codeLiteral, other.codeLiteral),
      codeString: l(codeString, other.codeString),
      codeSelection: l(codeSelection, other.codeSelection),
    );
  }
}

/// Anvil light theme semantic colors (`:root.light` in theme.css).
AnvilSemanticColors lightAnvilColors() {
  return AnvilSemanticColors(
    background: AnvilLightPalette.neutral50,
    surface: AnvilLightPalette.white,
    surfaceHovered: AnvilLightPalette.neutral500.withValues(alpha: 0.02),
    surfaceSecondary: AnvilLightPalette.neutral500.withValues(alpha: 0.04),
    overlay: AnvilLightPalette.white,
    overlayHovered: AnvilLightPalette.neutral50,
    inverse: AnvilLightPalette.neutral950,

    // Web light tier: brand primary is black-on-white (readability);
    // citrus brand fills remain in the dark/high-contrast tiers.
    fillBrandPrimary: AnvilLightPalette.neutral950,
    fillBrandPrimaryHovered: AnvilLightPalette.neutral950,
    fillBrandSecondary: AnvilLightPalette.neutral950,
    fillBrandSecondaryHovered: AnvilLightPalette.neutral950,
    fillDisabled: AnvilLightPalette.neutral300,
    fillOpaque: AnvilLightPalette.neutral950.withValues(alpha: 0.03),
    fillControlSelected: AnvilLightPalette.black,

    fillInfo: AnvilLightPalette.sky500,
    fillInfoSecondary: AnvilLightPalette.sky50,
    fillSuccess: AnvilLightPalette.emerald600,
    fillSuccessSecondary: AnvilLightPalette.emerald100,
    fillWarning: AnvilLightPalette.orange600,
    fillWarningSecondary: AnvilLightPalette.orange100,
    fillCritical: AnvilLightPalette.red600,
    fillCriticalSecondary: AnvilLightPalette.red100,
    fillPromo: AnvilLightPalette.violet500,
    fillPromoSecondary: AnvilLightPalette.violet100,
    fillPromoSecondaryHovered: AnvilLightPalette.violet200,

    foregroundNormal: AnvilLightPalette.neutral950,
    foregroundSubtle: AnvilLightPalette.neutral600,
    foregroundAccent: AnvilLightPalette.citrus700,
    foregroundWarning: AnvilLightPalette.orange600,
    foregroundDisabled: AnvilLightPalette.neutral500,
    foregroundOnFill: AnvilLightPalette.white,
    foregroundOnInverse: AnvilLightPalette.white,
    foregroundOnBrandPrimary: AnvilLightPalette.white,

    borderNormal: AnvilLightPalette.neutral950.withValues(alpha: 0.12),
    borderStrong: AnvilLightPalette.neutral950,
    borderInfo: AnvilLightPalette.sky500,
    borderSuccess: AnvilLightPalette.emerald600,
    borderWarning: AnvilLightPalette.orange600,
    borderCritical: AnvilLightPalette.red600,
    borderPromo: AnvilLightPalette.violet500,
    borderControlSelected: AnvilLightPalette.black,

    ring: AnvilLightPalette.citrus700,
    focusOutline: AnvilLightPalette.citrus700,
    progress: AnvilLightPalette.citrus700,
    progressRemaining: AnvilLightPalette.citrus700.withValues(alpha: 0.20),

    codeBackground: AnvilLightPalette.white,
    codeForeground: AnvilLightPalette.neutral950,
    codeMuted: AnvilLightPalette.neutral600,
    codeKeyword: AnvilLightPalette.citrus700,
    codeLiteral: AnvilLightPalette.sunset600,
    codeString: AnvilLightPalette.sky800,
    codeSelection: AnvilLightPalette.citrus500.withValues(alpha: 0.15),
  );
}

/// Anvil dark theme semantic colors (`:root.dark` in theme.css).
AnvilSemanticColors darkAnvilColors() => AnvilSemanticColors(
  background: AnvilDarkPalette.neutral100,
  surface: AnvilDarkPalette.neutral200,
  surfaceHovered: AnvilDarkPalette.neutral500.withValues(alpha: 0.07),
  surfaceSecondary: AnvilDarkPalette.neutral500.withValues(alpha: 0.15),
  overlay: AnvilDarkPalette.neutral200,
  overlayHovered: AnvilDarkPalette.neutral100,
  inverse: AnvilDarkPalette.neutral950,

  fillBrandPrimary: AnvilDarkPalette.citrus600,
  fillBrandPrimaryHovered: AnvilDarkPalette.citrus700,
  fillBrandSecondary: AnvilDarkPalette.neutral950,
  fillBrandSecondaryHovered: AnvilDarkPalette.neutral950,
  fillDisabled: AnvilDarkPalette.neutral600,
  fillOpaque: AnvilDarkPalette.neutral950.withValues(alpha: 0.03),
  fillControlSelected: AnvilDarkPalette.primary,

  fillInfo: AnvilDarkPalette.sky600,
  fillInfoSecondary: AnvilDarkPalette.sky50,
  fillSuccess: AnvilDarkPalette.emerald600,
  fillSuccessSecondary: AnvilDarkPalette.emerald50,
  fillWarning: AnvilDarkPalette.orange600,
  fillWarningSecondary: AnvilDarkPalette.orange50,
  fillCritical: AnvilDarkPalette.red600,
  fillCriticalSecondary: AnvilDarkPalette.red50,
  fillPromo: AnvilDarkPalette.violet600,
  fillPromoSecondary: AnvilDarkPalette.violet50,
  fillPromoSecondaryHovered: AnvilDarkPalette.violet100,

  foregroundNormal: AnvilDarkPalette.neutral950,
  foregroundSubtle: AnvilDarkPalette.neutral700,
  foregroundAccent: AnvilDarkPalette.citrus600,
  foregroundWarning: AnvilDarkPalette.orange600,
  foregroundDisabled: AnvilDarkPalette.neutral500,
  // `white`/`black` are flipped in the dark tier, matching the CSS.
  foregroundOnFill: AnvilDarkPalette.white,
  foregroundOnInverse: AnvilDarkPalette.white,
  foregroundOnBrandPrimary: _blackStatic,

  borderNormal: AnvilDarkPalette.neutral950.withValues(alpha: 0.25),
  borderStrong: AnvilDarkPalette.neutral950,
  borderInfo: AnvilDarkPalette.sky500,
  borderSuccess: AnvilDarkPalette.emerald600,
  borderWarning: AnvilDarkPalette.orange600,
  borderCritical: AnvilDarkPalette.red600,
  borderPromo: AnvilDarkPalette.violet500,
  borderControlSelected: AnvilDarkPalette.primary,

  ring: AnvilDarkPalette.citrus700,
  focusOutline: AnvilDarkPalette.citrus600,
  // The bare `:root` block of theme.css pins --progress to citrus-700 for
  // every tier (the dark block does not override it).
  progress: AnvilDarkPalette.citrus700,
  progressRemaining: AnvilDarkPalette.citrus700.withValues(alpha: 0.20),

  codeBackground: AnvilDarkPalette.neutral200,
  codeForeground: AnvilDarkPalette.neutral950,
  codeMuted: AnvilDarkPalette.neutral700,
  codeKeyword: AnvilDarkPalette.citrus700,
  codeLiteral: AnvilDarkPalette.sunset600,
  codeString: AnvilDarkPalette.sky800,
  codeSelection: AnvilDarkPalette.citrus500.withValues(alpha: 0.15),
);

/// Anvil light high-contrast semantic colors (`:root.light-high-contrast`).
AnvilSemanticColors lightHighContrastAnvilColors() => AnvilSemanticColors(
  background: AnvilLightHighContrastPalette.neutral50,
  surface: AnvilLightHighContrastPalette.white,
  surfaceHovered: AnvilLightHighContrastPalette.neutral500.withValues(
    alpha: 0.02,
  ),
  surfaceSecondary: AnvilLightHighContrastPalette.neutral500.withValues(
    alpha: 0.04,
  ),
  overlay: AnvilLightHighContrastPalette.white,
  overlayHovered: AnvilLightHighContrastPalette.neutral50,
  inverse: AnvilLightHighContrastPalette.neutral950,

  fillBrandPrimary: AnvilLightHighContrastPalette.citrus800,
  fillBrandPrimaryHovered: AnvilLightHighContrastPalette.citrus900,
  fillBrandSecondary: AnvilLightHighContrastPalette.neutral950,
  fillBrandSecondaryHovered: AnvilLightHighContrastPalette.neutral950,
  fillDisabled: AnvilLightHighContrastPalette.neutral300.withValues(
    alpha: 0.60,
  ),
  fillOpaque: AnvilLightHighContrastPalette.neutral950.withValues(alpha: 0.03),
  fillControlSelected: AnvilLightHighContrastPalette.black,

  fillInfo: AnvilLightHighContrastPalette.sky500,
  fillInfoSecondary: AnvilLightHighContrastPalette.sky50,
  fillSuccess: AnvilLightHighContrastPalette.emerald600,
  fillSuccessSecondary: AnvilLightHighContrastPalette.emerald100,
  fillWarning: AnvilLightHighContrastPalette.orange600,
  fillWarningSecondary: AnvilLightHighContrastPalette.orange100,
  fillCritical: AnvilLightHighContrastPalette.red800,
  fillCriticalSecondary: AnvilLightHighContrastPalette.red100,
  fillPromo: AnvilLightHighContrastPalette.violet500,
  fillPromoSecondary: AnvilLightHighContrastPalette.violet100,
  fillPromoSecondaryHovered: AnvilLightHighContrastPalette.violet200,

  foregroundNormal: AnvilLightHighContrastPalette.black,
  foregroundSubtle: AnvilLightHighContrastPalette.neutral800,
  foregroundAccent: AnvilLightHighContrastPalette.citrus700,
  foregroundWarning: AnvilLightHighContrastPalette.orange600,
  foregroundDisabled: AnvilLightHighContrastPalette.neutral500,
  foregroundOnFill: AnvilLightHighContrastPalette.white,
  foregroundOnInverse: AnvilLightHighContrastPalette.white,
  foregroundOnBrandPrimary: _blackStatic,

  borderNormal: AnvilLightHighContrastPalette.neutral950,
  borderStrong: AnvilLightHighContrastPalette.neutral950,
  borderInfo: AnvilLightHighContrastPalette.sky500,
  borderSuccess: AnvilLightHighContrastPalette.emerald600,
  borderWarning: AnvilLightHighContrastPalette.orange600,
  borderCritical: AnvilLightHighContrastPalette.red600,
  borderPromo: AnvilLightHighContrastPalette.violet500,
  borderControlSelected: AnvilLightHighContrastPalette.black,

  ring: AnvilLightHighContrastPalette.citrus700,
  focusOutline: AnvilLightHighContrastPalette.citrus700,
  progress: AnvilLightHighContrastPalette.citrus800,
  progressRemaining: AnvilLightHighContrastPalette.citrus800.withValues(
    alpha: 0.20,
  ),

  codeBackground: AnvilLightHighContrastPalette.white,
  codeForeground: AnvilLightHighContrastPalette.black,
  codeMuted: AnvilLightHighContrastPalette.neutral800,
  codeKeyword: AnvilLightHighContrastPalette.citrus900,
  codeLiteral: AnvilLightHighContrastPalette.sunset800,
  codeString: AnvilLightHighContrastPalette.sky950,
  codeSelection: AnvilLightHighContrastPalette.citrus500.withValues(
    alpha: 0.15,
  ),
);

/// Anvil dark high-contrast semantic colors (`:root.dark-high-contrast`).
///
/// Cascade note: the web applies `dark-high-contrast` as a *single* class —
/// the `:root.dark` override block does NOT apply. So this tier = `@theme`
/// defaults + the bare `:root` overrides (shadows, progress, code) + the
/// dark-high-contrast block. Notably: surfaces stay at the dark-HC defaults
/// (white→black flip, 2%/4% hover alpha), and `fillInfo`/`fillPromo` keep the
/// default 500 steps.
AnvilSemanticColors darkHighContrastAnvilColors() => AnvilSemanticColors(
  background: AnvilDarkHighContrastPalette.neutral50,
  surface: AnvilDarkHighContrastPalette
      .white, // flipped in the dark tier — resolves to black
  surfaceHovered: AnvilDarkHighContrastPalette.neutral500.withValues(
    alpha: 0.02,
  ),
  surfaceSecondary: AnvilDarkHighContrastPalette.neutral500.withValues(
    alpha: 0.04,
  ),
  overlay: AnvilDarkHighContrastPalette.white, // flipped — black
  overlayHovered: AnvilDarkHighContrastPalette.neutral50,
  inverse: AnvilDarkHighContrastPalette.neutral950,

  fillBrandPrimary: AnvilDarkHighContrastPalette.citrus800,
  fillBrandPrimaryHovered: AnvilDarkHighContrastPalette.citrus900,
  fillBrandSecondary: AnvilDarkHighContrastPalette.neutral950,
  fillBrandSecondaryHovered: AnvilDarkHighContrastPalette.neutral950,
  fillDisabled: AnvilDarkHighContrastPalette
      .black, // per CSS --fill-disabled: var(--color-black)
  fillOpaque: AnvilDarkHighContrastPalette.neutral950.withValues(alpha: 0.03),
  fillControlSelected: AnvilDarkHighContrastPalette.primary,

  fillInfo: AnvilDarkHighContrastPalette.sky500,
  fillInfoSecondary: AnvilDarkHighContrastPalette.sky50,
  fillSuccess: AnvilDarkHighContrastPalette.emerald600,
  fillSuccessSecondary: AnvilDarkHighContrastPalette.emerald50,
  fillWarning: AnvilDarkHighContrastPalette.orange600,
  fillWarningSecondary: AnvilDarkHighContrastPalette.orange50,
  fillCritical: AnvilDarkHighContrastPalette.red800,
  fillCriticalSecondary: AnvilDarkHighContrastPalette.red50,
  fillPromo: AnvilDarkHighContrastPalette.violet500,
  fillPromoSecondary: AnvilDarkHighContrastPalette.violet50,
  fillPromoSecondaryHovered: AnvilDarkHighContrastPalette.violet100,

  foregroundNormal: AnvilDarkHighContrastPalette
      .black, // flipped in the dark tier — resolves to white
  foregroundSubtle: AnvilDarkHighContrastPalette.neutral800,
  foregroundAccent: AnvilDarkHighContrastPalette.citrus800,
  foregroundWarning: AnvilDarkHighContrastPalette.orange600,
  foregroundDisabled: AnvilDarkHighContrastPalette.neutral500,
  foregroundOnFill:
      AnvilDarkHighContrastPalette.black, // flipped — resolves to white
  foregroundOnInverse:
      AnvilDarkHighContrastPalette.white, // flipped — resolves to black
  foregroundOnBrandPrimary: _blackStatic,

  borderNormal: AnvilDarkHighContrastPalette.neutral950,
  borderStrong: AnvilDarkHighContrastPalette.neutral950,
  borderInfo: AnvilDarkHighContrastPalette.sky800,
  borderSuccess: AnvilDarkHighContrastPalette.emerald800,
  borderWarning: AnvilDarkHighContrastPalette.orange800,
  borderCritical: AnvilDarkHighContrastPalette.red800,
  borderPromo: AnvilDarkHighContrastPalette.violet800,
  borderControlSelected: AnvilDarkHighContrastPalette.primary,

  ring: AnvilDarkHighContrastPalette.citrus700,
  focusOutline: AnvilDarkHighContrastPalette.citrus700,
  progress: AnvilDarkHighContrastPalette.citrus700,
  progressRemaining: AnvilDarkHighContrastPalette.citrus700.withValues(
    alpha: 0.20,
  ),

  codeBackground: AnvilDarkHighContrastPalette
      .white, // = --background-surface, flipped — black
  codeForeground: AnvilDarkHighContrastPalette.black,
  codeMuted: AnvilDarkHighContrastPalette.neutral800,
  codeKeyword: AnvilDarkHighContrastPalette.citrus900,
  codeLiteral: AnvilDarkHighContrastPalette.sunset800,
  codeString: AnvilDarkHighContrastPalette.sky950,
  codeSelection: AnvilDarkHighContrastPalette.citrus500.withValues(alpha: 0.15),
);

/// Resolves semantic colors for a given [AnvilThemeTier].
AnvilSemanticColors anvilSemanticColors(AnvilThemeTier tier) => switch (tier) {
  AnvilThemeTier.light => lightAnvilColors(),
  AnvilThemeTier.dark => darkAnvilColors(),
  AnvilThemeTier.lightHighContrast => lightHighContrastAnvilColors(),
  AnvilThemeTier.darkHighContrast => darkHighContrastAnvilColors(),
};
