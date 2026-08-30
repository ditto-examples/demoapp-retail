import 'package:flutter/material.dart';

import 'anvil_palette.dart';
import 'anvil_semantic_colors.dart';

/// Maps an [AnvilSemanticColors] tier onto a Material 3 [ColorScheme].
///
/// Applied decisions (mirrors the Android port, see
/// `android/docs/anvil-android-material-plan.md`):
/// - `primary` is Anvil's brand fill. Light tier: black fill with **white
///   content** (readability). Dark/HC tiers keep Ditto's signature
///   black-on-citrus.
/// - `tertiary` carries the violet "promo" accent.
/// - `error` carries the red "critical" status.
/// - Non-Material semantics (info/success/warning/promo surfaces, borders,
///   code colors…) remain available via [AnvilSemanticColors] instead of being
///   squeezed into a Material role.
ColorScheme _dittoColorScheme({
  required AnvilSemanticColors semantic,
  required Color primary,
  required Color onPrimary,
  required Color primaryContainer,
  required Color onPrimaryContainer,
  required Color secondary,
  required Color onSecondary,
  required Color secondaryContainer,
  required Color onSecondaryContainer,
  required Color tertiary,
  required Color onTertiary,
  required Color tertiaryContainer,
  required Color onTertiaryContainer,
  required Color error,
  required Color onError,
  required Color errorContainer,
  required Color onErrorContainer,
  required Color surfaceDim,
  required Color surfaceContainerLowest,
  required Color surfaceContainerLow,
  required Color surfaceContainer,
  required Color surfaceContainerHigh,
  required Color surfaceContainerHighest,
  required Color surfaceBright,
  required Color outline,
  required Color outlineVariant,
  required Color inversePrimary,
  required Brightness brightness,
}) {
  // Flutter merged `background` into `surface` (the background roles are
  // deprecated aliases); Anvil's separate `background` semantic stays
  // available via [AnvilSemanticColors].
  return ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: secondary,
    onSecondary: onSecondary,
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: onSecondaryContainer,
    tertiary: tertiary,
    onTertiary: onTertiary,
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: onTertiaryContainer,
    error: error,
    onError: onError,
    errorContainer: errorContainer,
    onErrorContainer: onErrorContainer,
    surface: semantic.surface,
    onSurface: semantic.foregroundNormal,
    onSurfaceVariant: semantic.foregroundSubtle,
    surfaceTint: primary,
    inverseSurface: semantic.inverse,
    onInverseSurface: semantic.foregroundOnInverse,
    inversePrimary: inversePrimary,
    outline: outline,
    outlineVariant: outlineVariant,
    scrim: Colors.black,
    surfaceDim: surfaceDim,
    surfaceBright: surfaceBright,
    // "Fixed" roles (M3 2024 spec): anchored variants for prominent
    // containers. Derived from the container roles until design provides
    // dedicated values.
    primaryFixed: primaryContainer,
    primaryFixedDim: primaryContainer,
    onPrimaryFixed: onPrimaryContainer,
    onPrimaryFixedVariant: onPrimaryContainer,
    secondaryFixed: secondaryContainer,
    secondaryFixedDim: secondaryContainer,
    onSecondaryFixed: onSecondaryContainer,
    onSecondaryFixedVariant: onSecondaryContainer,
    tertiaryFixed: tertiaryContainer,
    tertiaryFixedDim: tertiaryContainer,
    onTertiaryFixed: onTertiaryContainer,
    onTertiaryFixedVariant: onTertiaryContainer,
    surfaceContainerLowest: surfaceContainerLowest,
    surfaceContainerLow: surfaceContainerLow,
    surfaceContainer: surfaceContainer,
    surfaceContainerHigh: surfaceContainerHigh,
    surfaceContainerHighest: surfaceContainerHighest,
  );
}

/// Material 3 [ColorScheme] for Anvil's light tier.
ColorScheme anvilLightColorScheme() {
  final semantic = anvilSemanticColors(AnvilThemeTier.light);
  return _dittoColorScheme(
    semantic: semantic,
    primary: semantic.fillBrandPrimary,
    onPrimary: semantic.foregroundOnBrandPrimary,
    primaryContainer: AnvilLightPalette.citrus400,
    onPrimaryContainer: AnvilLightPalette.neutral950,
    secondary: semantic.fillBrandSecondary,
    onSecondary: semantic.foregroundOnFill,
    secondaryContainer: AnvilLightPalette.neutral200,
    onSecondaryContainer: AnvilLightPalette.neutral950,
    // violet500 with black content is the promo pair for secondary fills,
    // but M3 onTertiary is white — violet600 keeps that ≥4.5:1.
    tertiary: AnvilLightPalette.violet600,
    onTertiary: semantic.foregroundOnFill,
    tertiaryContainer: semantic.fillPromoSecondary,
    onTertiaryContainer: AnvilLightPalette.violet900,
    error: semantic.fillCritical,
    onError: semantic.foregroundOnFill,
    errorContainer: semantic.fillCriticalSecondary,
    onErrorContainer: AnvilLightPalette.red900,
    surfaceDim: AnvilLightPalette.neutral200,
    surfaceContainerLowest: AnvilLightPalette.white,
    surfaceContainerLow: AnvilLightPalette.neutral100,
    surfaceContainer: AnvilLightPalette.neutral100,
    surfaceContainerHigh: AnvilLightPalette.neutral200,
    surfaceContainerHighest: AnvilLightPalette.neutral200,
    surfaceBright: AnvilLightPalette.white,
    outline: AnvilLightPalette.neutral500,
    outlineVariant: AnvilLightPalette.neutral300,
    inversePrimary: AnvilLightPalette.citrus400,
    brightness: Brightness.light,
  );
}

/// Material 3 [ColorScheme] for Anvil's dark tier.
ColorScheme anvilDarkColorScheme() {
  final semantic = anvilSemanticColors(AnvilThemeTier.dark);
  return _dittoColorScheme(
    semantic: semantic,
    primary: semantic.fillBrandPrimary,
    onPrimary: semantic.foregroundOnBrandPrimary,
    primaryContainer: AnvilDarkPalette.citrus50,
    onPrimaryContainer: AnvilDarkPalette.citrus500,
    secondary: semantic.fillBrandSecondary,
    onSecondary: semantic.foregroundOnFill,
    secondaryContainer: AnvilDarkPalette.neutral300,
    onSecondaryContainer: AnvilDarkPalette.neutral950,
    tertiary: semantic.fillPromo,
    onTertiary: semantic.foregroundOnFill,
    tertiaryContainer: AnvilDarkPalette.violet50,
    onTertiaryContainer:
        AnvilDarkPalette.violet700, // violet500-dark would be only ~3.5:1 here
    error: semantic.fillCritical,
    onError: semantic.foregroundOnFill,
    errorContainer: AnvilDarkPalette.red50,
    onErrorContainer:
        AnvilDarkPalette.red600, // red500-dark is only ~4.2:1 on red50-dark
    surfaceDim: AnvilDarkPalette.neutral50,
    surfaceContainerLowest: AnvilDarkPalette.neutral50,
    surfaceContainerLow: AnvilDarkPalette.neutral100,
    surfaceContainer: AnvilDarkPalette.neutral200,
    surfaceContainerHigh: AnvilDarkPalette.neutral300,
    surfaceContainerHighest: AnvilDarkPalette.neutral400,
    surfaceBright: AnvilDarkPalette.neutral300,
    outline: AnvilDarkPalette.neutral500,
    outlineVariant: AnvilDarkPalette.neutral300,
    // inversePrimary renders on inverseSurface (near-white in dark), so it
    // must be the dark, adult citrus — dark-tier citrus100, not the flipped
    // citrus800 (which is near-white in this tier).
    inversePrimary: AnvilDarkPalette.citrus100,
    brightness: Brightness.dark,
  );
}

/// Material 3 [ColorScheme] for Anvil's light high-contrast tier.
ColorScheme anvilLightHighContrastColorScheme() {
  final semantic = anvilSemanticColors(AnvilThemeTier.lightHighContrast);
  return _dittoColorScheme(
    semantic: semantic,
    primary: semantic.fillBrandPrimary,
    onPrimary: semantic.foregroundOnBrandPrimary,
    primaryContainer: AnvilLightHighContrastPalette.citrus400,
    onPrimaryContainer: AnvilLightHighContrastPalette.neutral950,
    secondary: semantic.fillBrandSecondary,
    onSecondary: semantic.foregroundOnFill,
    secondaryContainer: AnvilLightHighContrastPalette.neutral200,
    onSecondaryContainer: AnvilLightHighContrastPalette.neutral950,
    tertiary: AnvilLightHighContrastPalette.violet600,
    onTertiary: semantic.foregroundOnFill,
    tertiaryContainer: semantic.fillPromoSecondary,
    onTertiaryContainer: AnvilLightHighContrastPalette.violet900,
    error: semantic.fillCritical,
    onError: semantic.foregroundOnFill,
    errorContainer: semantic.fillCriticalSecondary,
    onErrorContainer: AnvilLightHighContrastPalette.red900,
    surfaceDim: AnvilLightHighContrastPalette.neutral200,
    surfaceContainerLowest: AnvilLightHighContrastPalette.white,
    surfaceContainerLow: AnvilLightHighContrastPalette.neutral100,
    surfaceContainer: AnvilLightHighContrastPalette.neutral100,
    surfaceContainerHigh: AnvilLightHighContrastPalette.neutral200,
    surfaceContainerHighest: AnvilLightHighContrastPalette.neutral200,
    surfaceBright: AnvilLightHighContrastPalette.white,
    // HC tiers use opaque, strong borders (web: --border-normal: neutral-950).
    outline: AnvilLightHighContrastPalette.neutral950,
    outlineVariant: AnvilLightHighContrastPalette.neutral600,
    inversePrimary: AnvilLightHighContrastPalette.citrus400,
    brightness: Brightness.light,
  );
}

/// Material 3 [ColorScheme] for Anvil's dark high-contrast tier.
ColorScheme anvilDarkHighContrastColorScheme() {
  final semantic = anvilSemanticColors(AnvilThemeTier.darkHighContrast);
  return _dittoColorScheme(
    semantic: semantic,
    primary: semantic.fillBrandPrimary,
    onPrimary: semantic.foregroundOnBrandPrimary,
    primaryContainer: AnvilDarkHighContrastPalette.citrus50,
    onPrimaryContainer: AnvilDarkHighContrastPalette.citrus500,
    secondary: semantic.fillBrandSecondary,
    // The dark-HC web tier flips on-fill to white, but brand-secondary here
    // is the near-white neutral-950 — use brand-content black to stay legible.
    onSecondary: semantic.foregroundOnBrandPrimary,
    secondaryContainer: AnvilDarkHighContrastPalette.neutral300,
    onSecondaryContainer: AnvilDarkHighContrastPalette.neutral950,
    tertiary: semantic.fillPromo,
    onTertiary: semantic.foregroundOnFill,
    tertiaryContainer: AnvilDarkHighContrastPalette.violet50,
    // dark-HC ramps compress the 500-700 steps together; violet800 jumps to
    // pale lilac, which sits at AA on the dark violet-50 container.
    onTertiaryContainer: AnvilDarkHighContrastPalette.violet800,
    error: semantic.fillCritical,
    // Same as onSecondary: dark-HC "on fill" is white but the filled roles
    // here are the HC palette's light steps — black content stays legible.
    onError: semantic.foregroundOnBrandPrimary,
    errorContainer: AnvilDarkHighContrastPalette.red50,
    onErrorContainer: AnvilDarkHighContrastPalette
        .red800, // dark-HC mid steps compress together; jump to the pale step
    surfaceDim: AnvilDarkHighContrastPalette.neutral50,
    surfaceContainerLowest: AnvilDarkHighContrastPalette.neutral50,
    surfaceContainerLow: AnvilDarkHighContrastPalette.neutral100,
    surfaceContainer: AnvilDarkHighContrastPalette.neutral200,
    surfaceContainerHigh: AnvilDarkHighContrastPalette.neutral300,
    surfaceContainerHighest: AnvilDarkHighContrastPalette.neutral400,
    surfaceBright: AnvilDarkHighContrastPalette.neutral300,
    // HC tiers use opaque, strong borders (web: --border-normal: neutral-950).
    // The compressed dark-HC ramp has no mid-gray that reaches the 3:1 UI
    // minimum on black surfaces (neutral-700 is only 2.7:1), so the variant
    // steps down to the pale neutral-800 instead of a dead mid-gray.
    outline: AnvilDarkHighContrastPalette.neutral950,
    outlineVariant: AnvilDarkHighContrastPalette.neutral800,
    inversePrimary: AnvilDarkHighContrastPalette.citrus100,
    brightness: Brightness.dark,
  );
}

/// Resolves the [ColorScheme] for a given [AnvilThemeTier].
ColorScheme anvilColorScheme(AnvilThemeTier tier) => switch (tier) {
  AnvilThemeTier.light => anvilLightColorScheme(),
  AnvilThemeTier.dark => anvilDarkColorScheme(),
  AnvilThemeTier.lightHighContrast => anvilLightHighContrastColorScheme(),
  AnvilThemeTier.darkHighContrast => anvilDarkHighContrastColorScheme(),
};
