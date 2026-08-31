import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  darkAnvilColors,
  lightAnvilColors,
  type AnvilSemanticColors,
} from '../src/semantic.ts'

/**
 * WCAG contrast checks for the key Anvil semantic color pairs, light and
 * dark tiers. Ported from android/anvil-tokens ContrastTest.kt and
 * flutter/anvil test/contrast_test.dart.
 *
 * Reference: https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html
 * - 4.5:1 for normal text
 * - 3.0:1 for large text / non-text UI components
 */

function channel(hex2: string): number {
  const v = parseInt(hex2, 16) / 255
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function luminance(hex: string): number {
  const h = hex.replace('#', '').slice(0, 6) // ignore alpha channel
  return (
    0.2126 * channel(h.slice(0, 2)) +
    0.7152 * channel(h.slice(2, 4)) +
    0.0722 * channel(h.slice(4, 6))
  )
}

function ratio(a: string, b: string): number {
  const l1 = luminance(a)
  const l2 = luminance(b)
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1]
  return (hi + 0.05) / (lo + 0.05)
}

const tiers: Record<'light' | 'dark', AnvilSemanticColors> = {
  light: lightAnvilColors(),
  dark: darkAnvilColors(),
}

describe('body text meets AA on background and surface', () => {
  for (const [tier, colors] of Object.entries(tiers)) {
    it(tier, () => {
      assert.ok(
        ratio(colors.foregroundNormal, colors.background) >= 4.5,
        `${tier}: foregroundNormal/background = ${ratio(colors.foregroundNormal, colors.background)}`,
      )
      assert.ok(
        ratio(colors.foregroundNormal, colors.surface) >= 4.5,
        `${tier}: foregroundNormal/surface = ${ratio(colors.foregroundNormal, colors.surface)}`,
      )
    })
  }
})

describe('subtle text meets AA on background and surface', () => {
  for (const [tier, colors] of Object.entries(tiers)) {
    it(tier, () => {
      assert.ok(
        ratio(colors.foregroundSubtle, colors.background) >= 4.5,
        `${tier}: foregroundSubtle/background = ${ratio(colors.foregroundSubtle, colors.background)}`,
      )
      assert.ok(
        ratio(colors.foregroundSubtle, colors.surface) >= 4.5,
        `${tier}: foregroundSubtle/surface = ${ratio(colors.foregroundSubtle, colors.surface)}`,
      )
    })
  }
})

describe('brand primary fill meets WCAG AA for large text and UI (3:1)', () => {
  // Black-on-citrus is Ditto's signature in the dark tier; the web theme sits
  // at ~3.95:1 there — AA for large text/UI but not body text. Keep primary
  // text big/bold or use secondary fills for body-sized content.
  for (const [tier, colors] of Object.entries(tiers)) {
    it(tier, () => {
      assert.ok(
        ratio(colors.foregroundOnBrandPrimary, colors.fillBrandPrimary) >= 3.0,
        `${tier}: onBrandPrimary/brandPrimary = ${ratio(colors.foregroundOnBrandPrimary, colors.fillBrandPrimary)}`,
      )
    })
  }
})

describe('secondary status fills support AA body text', () => {
  for (const [tier, colors] of Object.entries(tiers)) {
    it(tier, () => {
      const secondaries: Record<string, string> = {
        info: colors.fillInfoSecondary,
        success: colors.fillSuccessSecondary,
        warning: colors.fillWarningSecondary,
        critical: colors.fillCriticalSecondary,
        promo: colors.fillPromoSecondary,
      }
      for (const [name, bg] of Object.entries(secondaries)) {
        assert.ok(
          ratio(colors.foregroundNormal, bg) >= 4.5,
          `${tier}: foregroundNormal/${name}-secondary = ${ratio(colors.foregroundNormal, bg)}`,
        )
      }
    })
  }
})

describe('documented floors for known sub-AA web pairings', () => {
  for (const [tier, colors] of Object.entries(tiers)) {
    it(tier, () => {
      assert.ok(
        ratio(colors.progress, colors.background) >= 2.5,
        `${tier}: progress/background = ${ratio(colors.progress, colors.background)}`,
      )
      const fills: Record<string, string> = {
        info: colors.fillInfo,
        success: colors.fillSuccess,
        warning: colors.fillWarning,
        critical: colors.fillCritical,
        promo: colors.fillPromo,
      }
      for (const [name, fill] of Object.entries(fills)) {
        assert.ok(
          ratio(colors.foregroundOnFill, fill) >= 2.5,
          `${tier}: onFill/${name} = ${ratio(colors.foregroundOnFill, fill)}`,
        )
      }
      assert.ok(
        ratio(colors.foregroundDisabled, colors.background) >= 1.7,
        `${tier}: disabled/background = ${ratio(colors.foregroundDisabled, colors.background)}`,
      )
    })
  }
})

describe('accent and warning foregrounds read on background', () => {
  // Citrus accent is ~2.8:1 on light backgrounds — faithful to the web theme;
  // floor guards against regression. Prefer normal/subtle for critical text.
  for (const [tier, colors] of Object.entries(tiers)) {
    it(tier, () => {
      assert.ok(
        ratio(colors.foregroundAccent, colors.background) >= 2.5,
        `${tier}: foregroundAccent/background = ${ratio(colors.foregroundAccent, colors.background)}`,
      )
      assert.ok(
        ratio(colors.foregroundWarning, colors.background) >= 3.0,
        `${tier}: foregroundWarning/background = ${ratio(colors.foregroundWarning, colors.background)}`,
      )
    })
  }
})
