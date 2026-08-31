import 'dart:ui' show Color;

import 'package:anvil/anvil.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast checks for the key Anvil semantic color pairs, across all
/// four tiers. These guard the theme against palette changes that would break
/// readability in Flutter apps.
///
/// Reference: https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html
/// - 4.5:1 for normal text
/// - 3.0:1 for large text / non-text UI components
double _ratio(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final hi = l1 >= l2 ? l1 : l2;
  final lo = l1 >= l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final tiers = <String, AnvilSemanticColors>{
    'light': lightAnvilColors(),
    'dark': darkAnvilColors(),
    'light-high-contrast': lightHighContrastAnvilColors(),
    'dark-high-contrast': darkHighContrastAnvilColors(),
  };

  test('body text meets AA on background and surface', () {
    for (final MapEntry(key: tier, value: colors) in tiers.entries) {
      expect(
        _ratio(colors.foregroundNormal, colors.background),
        greaterThanOrEqualTo(4.5),
        reason:
            '$tier: foregroundNormal/background = ${_ratio(colors.foregroundNormal, colors.background)}',
      );
      expect(
        _ratio(colors.foregroundNormal, colors.surface),
        greaterThanOrEqualTo(4.5),
        reason:
            '$tier: foregroundNormal/surface = ${_ratio(colors.foregroundNormal, colors.surface)}',
      );
    }
  });

  test('subtle text meets AA on background and surface', () {
    for (final MapEntry(key: tier, value: colors) in tiers.entries) {
      expect(
        _ratio(colors.foregroundSubtle, colors.background),
        greaterThanOrEqualTo(4.5),
        reason:
            '$tier: foregroundSubtle/background = ${_ratio(colors.foregroundSubtle, colors.background)}',
      );
      expect(
        _ratio(colors.foregroundSubtle, colors.surface),
        greaterThanOrEqualTo(4.5),
        reason:
            '$tier: foregroundSubtle/surface = ${_ratio(colors.foregroundSubtle, colors.surface)}',
      );
    }
  });

  test('brand primary fill meets WCAG AA for large text and UI', () {
    // The light tier is white-on-black (~21:1). Black-on-citrus is Ditto's
    // signature in the dark/HC tiers; the web theme sits at ~3.95:1 there,
    // which satisfies WCAG AA for large text (18pt/14pt bold) and non-text
    // UI components (3:1) but NOT AA body text (4.5:1). This test guards
    // the brand value; use larger/bold text on primary fills, or the M3
    // `primaryContainer` role for body-sized content.
    for (final MapEntry(key: tier, value: colors) in tiers.entries) {
      expect(
        _ratio(colors.foregroundOnBrandPrimary, colors.fillBrandPrimary),
        greaterThanOrEqualTo(3.0),
        reason:
            '$tier: onBrandPrimary/brandPrimary = ${_ratio(colors.foregroundOnBrandPrimary, colors.fillBrandPrimary)}',
      );
    }
  });

  test('secondary status fills support AA body text', () {
    // On the web, status-via-secondary-fill is rendered with the normal
    // foreground, not with the saturated fill color — mirror that here.
    for (final MapEntry(key: tier, value: colors) in tiers.entries) {
      final secondaries = <String, Color>{
        'info': colors.fillInfoSecondary,
        'success': colors.fillSuccessSecondary,
        'warning': colors.fillWarningSecondary,
        'critical': colors.fillCriticalSecondary,
        'promo': colors.fillPromoSecondary,
      };
      for (final MapEntry(key: name, value: bg) in secondaries.entries) {
        expect(
          _ratio(colors.foregroundNormal, bg),
          greaterThanOrEqualTo(4.5),
          reason:
              '$tier: foregroundNormal/$name-secondary = ${_ratio(colors.foregroundNormal, bg)}',
        );
      }
    }
  });

  test('documented floors for known sub-AA web pairings', () {
    // These pairs are faithful ports of Anvil's web values that fall below
    // WCAG guidance. The floors exist to catch regressions; raising the web
    // tokens would be a design change, made in CSS.
    for (final MapEntry(key: tier, value: colors) in tiers.entries) {
      // progress on background: light tier is ~2.78 (citrus-700 on
      // neutral-50); other tiers are 5+.
      expect(
        _ratio(colors.progress, colors.background),
        greaterThanOrEqualTo(2.5),
        reason:
            '$tier: progress/background = ${_ratio(colors.progress, colors.background)}',
      );
      // white on-fill on the light status fills: sky-500 is ~2.71.
      final fills = <String, Color>{
        'info': colors.fillInfo,
        'success': colors.fillSuccess,
        'warning': colors.fillWarning,
        'critical': colors.fillCritical,
        'promo': colors.fillPromo,
      };
      for (final MapEntry(key: name, value: fill) in fills.entries) {
        // dark-high-contrast: onFill is white (CSS) but fills are the
        // pale HC steps (e.g. red-800 = #FFC9C9), giving ~1.45:1 —
        // a web-side oddity we port faithfully. The M3 color scheme
        // deliberately uses black content on those fills, so the pair
        // is excluded here. Don't render `foregroundOnFill` text on the
        // dark-HC status fills.
        if (tier == 'dark-high-contrast') continue;
        expect(
          _ratio(colors.foregroundOnFill, fill),
          greaterThanOrEqualTo(2.5),
          reason:
              '$tier: onFill/$name = ${_ratio(colors.foregroundOnFill, fill)}',
        );
      }
      // disabled foreground: WCAG-exempt; dark-HC is the tightest at ~1.79.
      expect(
        _ratio(colors.foregroundDisabled, colors.background),
        greaterThanOrEqualTo(1.7),
        reason:
            '$tier: disabled/background = ${_ratio(colors.foregroundDisabled, colors.background)}',
      );
    }
  });

  test('accent and warning foregrounds read on background', () {
    for (final MapEntry(key: tier, value: colors) in tiers.entries) {
      // NOTE: Anvil's citrus accent sits at ~2.8:1 on light backgrounds,
      // below WCAG AA even for large text. We mirror the web theme
      // faithfully; this floor guards against accidental regression.
      // Prefer `foregroundSubtle`/`foregroundNormal` for critical text.
      expect(
        _ratio(colors.foregroundAccent, colors.background),
        greaterThanOrEqualTo(2.5),
        reason:
            '$tier: foregroundAccent/background = ${_ratio(colors.foregroundAccent, colors.background)}',
      );
      expect(
        _ratio(colors.foregroundWarning, colors.background),
        greaterThanOrEqualTo(3.0),
        reason:
            '$tier: foregroundWarning/background = ${_ratio(colors.foregroundWarning, colors.background)}',
      );
    }
  });
}
