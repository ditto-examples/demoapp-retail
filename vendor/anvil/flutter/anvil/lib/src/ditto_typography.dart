import 'package:flutter/material.dart';

/// Ditto UI sans typeface (Inter, OFL-licensed) bundled with this package.
const String dittoFontFamily = 'packages/anvil/Inter';

/// Ditto monospace typeface (IBM Plex Mono, OFL-licensed) bundled with this
/// package. Use for code samples, keys, and other literal text.
const String dittoMonoFontFamily = 'packages/anvil/IBMPlexMono';

/// Builds the Anvil [TextTheme] for Material 3.
///
/// Sizes follow Material's defaults (platform consistency). Ditto's typefaces
/// carry the brand:
/// - [brandFontFamily] is used for `display*` and `headline*` styles. Pass the
///   Kairos Sans font family here for the full Ditto look; Kairos is a
///   commercial Monotype typeface and is intentionally **not** bundled with
///   this package, so the default falls back to [fontFamily] (Inter).
/// - [fontFamily] (Inter) is used for `title*`, `body*`, and `label*`.
///
/// The base text color comes from [brightness] (Material's white/black
/// default text themes) so text is readable in both light and dark tiers.
TextTheme dittoTextTheme({
  String fontFamily = dittoFontFamily,
  String? brandFontFamily,
  TextTheme? base,
  Brightness brightness = Brightness.light,
}) {
  final brand = brandFontFamily ?? fontFamily;
  final b =
      base ??
      (brightness == Brightness.dark
          ? Typography.material2021().white
          : Typography.material2021().black);
  return TextTheme(
    displayLarge: b.displayLarge?.copyWith(fontFamily: brand),
    displayMedium: b.displayMedium?.copyWith(fontFamily: brand),
    displaySmall: b.displaySmall?.copyWith(fontFamily: brand),
    headlineLarge: b.headlineLarge?.copyWith(fontFamily: brand),
    headlineMedium: b.headlineMedium?.copyWith(fontFamily: brand),
    headlineSmall: b.headlineSmall?.copyWith(fontFamily: brand),
    titleLarge: b.titleLarge?.copyWith(fontFamily: fontFamily),
    titleMedium: b.titleMedium?.copyWith(fontFamily: fontFamily),
    titleSmall: b.titleSmall?.copyWith(fontFamily: fontFamily),
    bodyLarge: b.bodyLarge?.copyWith(fontFamily: fontFamily),
    bodyMedium: b.bodyMedium?.copyWith(fontFamily: fontFamily),
    bodySmall: b.bodySmall?.copyWith(fontFamily: fontFamily),
    labelLarge: b.labelLarge?.copyWith(fontFamily: fontFamily),
    labelMedium: b.labelMedium?.copyWith(fontFamily: fontFamily),
    labelSmall: b.labelSmall?.copyWith(fontFamily: fontFamily),
  );
}

/// Code text style built on [dittoMonoFontFamily].
TextStyle dittoCodeStyle(TextStyle base) =>
    base.copyWith(fontFamily: dittoMonoFontFamily);
