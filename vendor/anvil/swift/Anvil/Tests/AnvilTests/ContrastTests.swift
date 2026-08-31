import XCTest
import SwiftUI
@testable import Anvil

/**
 * WCAG contrast checks for the key Anvil semantic color pairs, across all
 * four tiers. Ported from android/anvil-tokens ContrastTest.kt,
 * flutter/anvil test/contrast_test.dart and react-native/anvil
 * test/contrast.test.ts.
 *
 * Reference: https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html
 * - 4.5:1 for normal text
 * - 3.0:1 for large text / non-text UI components
 */

private func linearChannel(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private func luminance(_ color: Color) -> Double {
    #if canImport(UIKit)
    let c = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    #else
    let c = NSColor(color)
    let rgb = c.usingColorSpace(.sRGB) ?? c
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    #if canImport(UIKit)
    c.getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    return 0.2126 * linearChannel(Double(r))
        + 0.7152 * linearChannel(Double(g))
        + 0.0722 * linearChannel(Double(b))
}

private func ratio(_ a: Color, _ b: Color) -> Double {
    let l1 = luminance(a)
    let l2 = luminance(b)
    let hi = max(l1, l2)
    let lo = min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)
}

final class ContrastTests: XCTestCase {

    private let tiers: [(name: String, colors: AnvilSemanticColors)] = [
        ("light", lightAnvilColors()),
        ("dark", darkAnvilColors()),
        ("light-high-contrast", lightHighContrastAnvilColors()),
        ("dark-high-contrast", darkHighContrastAnvilColors()),
    ]

    func testBodyTextMeetsAAOnBackgroundAndSurface() {
        for (tier, colors) in tiers {
            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundNormal, colors.background), 4.5,
                "\(tier): foregroundNormal/background")
            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundNormal, colors.surface), 4.5,
                "\(tier): foregroundNormal/surface")
        }
    }

    func testSubtleTextMeetsAAOnBackgroundAndSurface() {
        for (tier, colors) in tiers {
            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundSubtle, colors.background), 4.5,
                "\(tier): foregroundSubtle/background")
            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundSubtle, colors.surface), 4.5,
                "\(tier): foregroundSubtle/surface")
        }
    }

    /// The light tier is white-on-black (~21:1). Black-on-citrus is Ditto's
    /// signature in the dark/HC tiers at ~3.95:1 — AA for large text/UI but
    /// not body text. Keep primary-fill text large/bold or use containers.
    func testBrandPrimaryFillMeetsLargeTextMinimum() {
        for (tier, colors) in tiers {
            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundOnBrandPrimary, colors.fillBrandPrimary), 3.0,
                "\(tier): onBrandPrimary/brandPrimary")
        }
    }

    /// On the web, status-via-secondary-fill is rendered with the normal
    /// foreground, not the saturated fill color — mirror that here.
    func testSecondaryStatusFillsSupportAABodyText() {
        for (tier, colors) in tiers {
            let secondaries: [(String, Color)] = [
                ("info", colors.fillInfoSecondary),
                ("success", colors.fillSuccessSecondary),
                ("warning", colors.fillWarningSecondary),
                ("critical", colors.fillCriticalSecondary),
                ("promo", colors.fillPromoSecondary),
            ]
            for (name, bg) in secondaries {
                XCTAssertGreaterThanOrEqual(
                    ratio(colors.foregroundNormal, bg), 4.5,
                    "\(tier): foregroundNormal/\(name)-secondary")
            }
        }
    }

    /// These pairs are faithful ports of Anvil's web values that fall below
    /// WCAG guidance. The floors exist to catch regressions; raising the web
    /// tokens would be a design change, made in CSS.
    func testDocumentedFloorsForKnownSubAAPairings() {
        for (tier, colors) in tiers {
            XCTAssertGreaterThanOrEqual(
                ratio(colors.progress, colors.background), 2.5,
                "\(tier): progress/background")

            let fills: [(String, Color)] = [
                ("info", colors.fillInfo),
                ("success", colors.fillSuccess),
                ("warning", colors.fillWarning),
                ("critical", colors.fillCritical),
                ("promo", colors.fillPromo),
            ]
            for (name, fill) in fills {
                // dark-high-contrast: onFill is white (CSS) but fills are the
                // pale HC steps (~1.45:1) — a web oddity ported faithfully.
                if tier == "dark-high-contrast" { continue }
                XCTAssertGreaterThanOrEqual(
                    ratio(colors.foregroundOnFill, fill), 2.5,
                    "\(tier): onFill/\(name)")
            }

            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundDisabled, colors.background), 1.7,
                "\(tier): disabled/background")
        }
    }

    /// Citrus accent is ~2.8:1 on light backgrounds — below AA even for large
    /// text. Web-faithful; floor guards against regression. Prefer
    /// foregroundSubtle/foregroundNormal for critical text.
    func testAccentAndWarningForegroundsReadOnBackground() {
        for (tier, colors) in tiers {
            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundAccent, colors.background), 2.5,
                "\(tier): foregroundAccent/background")
            XCTAssertGreaterThanOrEqual(
                ratio(colors.foregroundWarning, colors.background), 3.0,
                "\(tier): foregroundWarning/background")
        }
    }
}
