import 'package:flutter/material.dart';

import 'anvil_palette.dart';
import 'anvil_semantic_colors.dart';
import 'ditto_color_schemes.dart';
import 'ditto_typography.dart';

/// Which Ditto theme the app should resolve to.
enum DittoThemeMode {
  /// Follow the platform light/dark setting.
  system,
  light,
  dark,
}

/// Builds the Ditto [ThemeData] for the given options — for apps that own
/// their `MaterialApp` theming. Equivalent to what [DittoTheme] applies
/// internally.
ThemeData dittoThemeData({
  AnvilThemeTier tier = AnvilThemeTier.light,
  String? brandFontFamily,
}) {
  final isDark =
      tier == AnvilThemeTier.dark || tier == AnvilThemeTier.darkHighContrast;
  final colorScheme = anvilColorScheme(tier);
  return ThemeData(
    useMaterial3: true,
    brightness: isDark ? Brightness.dark : Brightness.light,
    colorScheme: colorScheme,
    textTheme: dittoTextTheme(
      brandFontFamily: brandFontFamily,
      brightness: isDark ? Brightness.dark : Brightness.light,
    ),
    extensions: [anvilSemanticColors(tier)],
  );
}

/// Ditto brand theme for Flutter apps using Material 3.
///
/// Wrap [child] in `DittoTheme` at the root of your app (under `MaterialApp`):
///
/// ```dart
/// MaterialApp(
///   home: DittoTheme(
///     child: AppRoot(), // every M3 widget now uses Ditto colors + Inter
///   ),
/// )
/// ```
///
/// Or theme the `MaterialApp` directly with [dittoThemeData].
class DittoTheme extends StatelessWidget {
  const DittoTheme({
    super.key,
    this.mode = DittoThemeMode.system,
    this.highContrast = false,
    this.brandFontFamily,
    required this.child,
  });

  /// Light, dark, or follow-system (default).
  final DittoThemeMode mode;

  /// When `true`, uses Anvil's high-contrast color tier (mirrors Anvil's
  /// `light-high-contrast` / `dark-high-contrast` web themes).
  final bool highContrast;

  /// Optional typeface for display/headline styles — Kairos Sans is Ditto's
  /// brand font but is not bundled for licensing reasons; supply its family
  /// name here if you have a license. Falls back to Inter.
  final String? brandFontFamily;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = switch (mode) {
      DittoThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
      DittoThemeMode.light => false,
      DittoThemeMode.dark => true,
    };
    final tier = switch ((dark, highContrast)) {
      (true, true) => AnvilThemeTier.darkHighContrast,
      (true, false) => AnvilThemeTier.dark,
      (false, true) => AnvilThemeTier.lightHighContrast,
      (false, false) => AnvilThemeTier.light,
    };
    return Theme(
      data: dittoThemeData(tier: tier, brandFontFamily: brandFontFamily),
      child: child,
    );
  }
}

/// Access Anvil's extended (semantic) colors that have no Material 3 role —
/// e.g. `DittoColors.of(context).fillSuccess`, `.borderWarning`,
/// `.codeKeyword`.
///
/// ```dart
/// Text('Synced', style: TextStyle(color: DittoColors.of(context).fillSuccess))
/// ```
///
/// Falls back to the light tier when read outside a [DittoTheme].
extension DittoColors on BuildContext {
  AnvilSemanticColors get dittoColors =>
      Theme.of(this).extension<AnvilSemanticColors>() ??
      anvilSemanticColors(AnvilThemeTier.light);
}
