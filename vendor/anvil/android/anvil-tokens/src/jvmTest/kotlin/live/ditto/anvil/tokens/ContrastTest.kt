package live.ditto.anvil.tokens

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * WCAG contrast checks for the key Anvil semantic color pairs, across all
 * four tiers. These guard the theme against palette changes that would break
 * readability in Android apps.
 *
 * Reference: https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html
 * - 4.5:1 for normal text
 * - 3.0:1 for large text / non-text UI components
 */
class ContrastTest {

    private fun ratio(a: Color, b: Color): Double {
        val l1 = a.luminance()
        val l2 = b.luminance()
        val (hi, lo) = if (l1 >= l2) l1 to l2 else l2 to l1
        return (hi + 0.05) / (lo + 0.05)
    }

    private val tiers = mapOf(
        "light" to lightAnvilColors(),
        "dark" to darkAnvilColors(),
        "light-high-contrast" to lightHighContrastAnvilColors(),
        "dark-high-contrast" to darkHighContrastAnvilColors(),
    )

    @Test
    fun `body text meets AA on background and surface`() {
        for ((tier, colors) in tiers) {
            assertTrue(
                ratio(colors.foregroundNormal, colors.background) >= 4.5,
                "$tier: foregroundNormal/background = ${ratio(colors.foregroundNormal, colors.background)}",
            )
            assertTrue(
                ratio(colors.foregroundNormal, colors.surface) >= 4.5,
                "$tier: foregroundNormal/surface = ${ratio(colors.foregroundNormal, colors.surface)}",
            )
        }
    }

    @Test
    fun `subtle text meets AA on background and surface`() {
        for ((tier, colors) in tiers) {
            assertTrue(
                ratio(colors.foregroundSubtle, colors.background) >= 4.5,
                "$tier: foregroundSubtle/background = ${ratio(colors.foregroundSubtle, colors.background)}",
            )
            assertTrue(
                ratio(colors.foregroundSubtle, colors.surface) >= 4.5,
                "$tier: foregroundSubtle/surface = ${ratio(colors.foregroundSubtle, colors.surface)}",
            )
        }
    }

    @Test
    fun `brand primary fill meets WCAG AA for large text and UI`() {
        // The light tier is white-on-black (~21:1). Black-on-citrus is Ditto's
        // signature in the dark/HC tiers; the web theme sits at ~3.95:1 there,
        // which satisfies WCAG AA for large text (18pt/14pt bold) and non-text
        // UI components (3:1) but NOT AA body text (4.5:1). This test guards
        // the brand value; use larger/bold text on primary fills, or the M3
        // `primaryContainer` role for body-sized content.
        for ((tier, colors) in tiers) {
            assertTrue(
                ratio(colors.foregroundOnBrandPrimary, colors.fillBrandPrimary) >= 3.0,
                "$tier: onBrandPrimary/brandPrimary = ${ratio(colors.foregroundOnBrandPrimary, colors.fillBrandPrimary)}",
            )
        }
    }

    @Test
    fun `secondary status fills support AA body text`() {
        // On the web, status-via-secondary-fill is rendered with the normal
        // foreground, not with the saturated fill color — mirror that here.
        for ((tier, colors) in tiers) {
            val secondaries = listOf(
                "info" to colors.fillInfoSecondary,
                "success" to colors.fillSuccessSecondary,
                "warning" to colors.fillWarningSecondary,
                "critical" to colors.fillCriticalSecondary,
                "promo" to colors.fillPromoSecondary,
            )
            for ((name, bg) in secondaries) {
                assertTrue(
                    ratio(colors.foregroundNormal, bg) >= 4.5,
                    "$tier: foregroundNormal/$name-secondary = ${ratio(colors.foregroundNormal, bg)}",
                )
            }
        }
    }

    @Test
    fun `documented floors for known sub-AA web pairings`() {
        // These pairs are faithful ports of Anvil's web values that fall below
        // WCAG guidance. The floors exist to catch regressions; raising the web
        // tokens would be a design change, made in CSS.
        for ((tier, colors) in tiers) {
            // progress on background: light tier is ~2.78 (citrus-700 on
            // neutral-50); other tiers are 5+.
            assertTrue(
                ratio(colors.progress, colors.background) >= 2.5,
                "$tier: progress/background = ${ratio(colors.progress, colors.background)}",
            )
            // white on-fill on the light status fills: sky-500 is ~2.71.
            for ((name, fill) in listOf(
                "info" to colors.fillInfo,
                "success" to colors.fillSuccess,
                "warning" to colors.fillWarning,
                "critical" to colors.fillCritical,
                "promo" to colors.fillPromo,
            )) {
                // dark-high-contrast: onFill is white (CSS) but fills are the
                // pale HC steps (e.g. red-800 = #FFC9C9), giving ~1.45:1 —
                // a web-side oddity we port faithfully. The M3 color scheme
                // deliberately uses black content on those fills, so the pair
                // is excluded here. Don't render `foregroundOnFill` text on the
                // dark-HC status fills.
                if (tier == "dark-high-contrast") continue
                assertTrue(
                    ratio(colors.foregroundOnFill, fill) >= 2.5,
                    "$tier: onFill/$name = ${ratio(colors.foregroundOnFill, fill)}",
                )
            }
            // disabled foreground: WCAG-exempt; dark-HC is the tightest at ~1.79.
            assertTrue(
                ratio(colors.foregroundDisabled, colors.background) >= 1.7,
                "$tier: disabled/background = ${ratio(colors.foregroundDisabled, colors.background)}",
            )
        }
    }

    @Test
    fun `accent and warning foregrounds read on background`() {
        for ((tier, colors) in tiers) {
            // NOTE: Anvil's citrus accent sits at ~2.8:1 on light backgrounds,
            // below WCAG AA even for large text. We mirror the web theme
            // faithfully; this floor guards against accidental regression.
            // Prefer `foregroundSubtle`/`foregroundNormal` for critical text.
            assertTrue(
                ratio(colors.foregroundAccent, colors.background) >= 2.5,
                "$tier: foregroundAccent/background = ${ratio(colors.foregroundAccent, colors.background)}",
            )
            assertTrue(
                ratio(colors.foregroundWarning, colors.background) >= 3.0,
                "$tier: foregroundWarning/background = ${ratio(colors.foregroundWarning, colors.background)}",
            )
        }
    }
}
