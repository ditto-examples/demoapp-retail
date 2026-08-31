import 'dart:ui' show Color;

import 'package:anvil/anvil.dart';
import 'package:flutter/material.dart' show ColorScheme;
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast guards on the shipped Material 3 [ColorScheme] mappings —
/// the semantic-layer tests live in `contrast_test.dart`; these guard the
/// Material role assignments themselves (the layer where contrast regressions
/// actually ship).
double _ratio(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final hi = l1 >= l2 ? l1 : l2;
  final lo = l1 >= l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final schemes = <String, ColorScheme>{
    'light': anvilLightColorScheme(),
    'dark': anvilDarkColorScheme(),
    'light-high-contrast': anvilLightHighContrastColorScheme(),
    'dark-high-contrast': anvilDarkHighContrastColorScheme(),
  };

  test('container pairs meet AA body text', () {
    for (final MapEntry(key: tier, value: s) in schemes.entries) {
      final pairs = <String, (Color, Color)>{
        'primaryContainer': (s.onPrimaryContainer, s.primaryContainer),
        'secondaryContainer': (s.onSecondaryContainer, s.secondaryContainer),
        'tertiaryContainer': (s.onTertiaryContainer, s.tertiaryContainer),
        'errorContainer': (s.onErrorContainer, s.errorContainer),
        'surface/onSurface': (s.onSurface, s.surface),
      };
      for (final MapEntry(key: name, value: pair) in pairs.entries) {
        expect(
          _ratio(pair.$1, pair.$2),
          greaterThanOrEqualTo(4.5),
          reason: '$tier: $name = ${_ratio(pair.$1, pair.$2)}',
        );
      }
    }
  });

  test('filled role pairs meet AA large-text or UI minimums', () {
    for (final MapEntry(key: tier, value: s) in schemes.entries) {
      expect(
        _ratio(s.onPrimary, s.primary),
        greaterThanOrEqualTo(3.0),
        reason: '$tier: onPrimary/primary = ${_ratio(s.onPrimary, s.primary)}',
      );
      expect(
        _ratio(s.onSecondary, s.secondary),
        greaterThanOrEqualTo(3.0),
        reason:
            '$tier: onSecondary/secondary = ${_ratio(s.onSecondary, s.secondary)}',
      );
      expect(
        _ratio(s.onTertiary, s.tertiary),
        greaterThanOrEqualTo(4.5),
        reason:
            '$tier: onTertiary/tertiary = ${_ratio(s.onTertiary, s.tertiary)}',
      );
      expect(
        _ratio(s.onError, s.error),
        greaterThanOrEqualTo(3.0),
        reason: '$tier: onError/error = ${_ratio(s.onError, s.error)}',
      );
    }
  });

  test('hc tiers keep outlines at WCAG UI minimum', () {
    // In high-contrast tiers outlines must remain WCAG 1.4.11-visible (3:1)
    // — HC is precisely the tier where border identification matters.
    // Non-HC tiers intentionally allow subtler decorative variants.
    for (final tier in const ['light-high-contrast', 'dark-high-contrast']) {
      final s = schemes[tier]!;
      expect(
        _ratio(s.outline, s.surface),
        greaterThanOrEqualTo(3.0),
        reason: '$tier: outline/surface = ${_ratio(s.outline, s.surface)}',
      );
      expect(
        _ratio(s.outlineVariant, s.surface),
        greaterThanOrEqualTo(3.0),
        reason:
            '$tier: outlineVariant/surface = ${_ratio(s.outlineVariant, s.surface)}',
      );
    }
    // Non-HC variant borders are decorative (mirrors the web alpha borders);
    // floor is intentionally lenient — the HC tiers above are the HC contract.
    for (final tier in const ['light', 'dark']) {
      final s = schemes[tier]!;
      expect(
        _ratio(s.outlineVariant, s.surface),
        greaterThanOrEqualTo(1.4),
        reason:
            '$tier: outlineVariant/surface = ${_ratio(s.outlineVariant, s.surface)}',
      );
    }
  });

  test('inverse roles meet AA', () {
    for (final MapEntry(key: tier, value: s) in schemes.entries) {
      expect(
        _ratio(s.onInverseSurface, s.inverseSurface),
        greaterThanOrEqualTo(4.5),
        reason:
            '$tier: inverseOnSurface/inverseSurface = ${_ratio(s.onInverseSurface, s.inverseSurface)}',
      );
      expect(
        _ratio(s.inversePrimary, s.inverseSurface),
        greaterThanOrEqualTo(3.0),
        reason:
            '$tier: inversePrimary/inverseSurface = ${_ratio(s.inversePrimary, s.inverseSurface)}',
      );
    }
  });
}
