import SwiftUI

/// Which Ditto theme the app should resolve to.
public enum DittoThemeMode: Sendable {
    /// Follow the device light/dark setting (SwiftUI `colorScheme`).
    case system
    case light
    case dark
}

// MARK: - Environment

private struct AnvilIsDarkKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AnvilColorsKey: EnvironmentKey {
    static let defaultValue = lightAnvilColors()
}

public extension EnvironmentValues {
    /// Resolved semantic Anvil colors for the active tier. Falls back to the
    /// light tier outside a `DittoTheme`.
    var dittoColors: AnvilSemanticColors {
        get { self[AnvilColorsKey.self] }
        set { self[AnvilColorsKey.self] = newValue }
    }

    /// True when the active tier is dark.
    var dittoIsDark: Bool {
        get { self[AnvilIsDarkKey.self] }
        set { self[AnvilIsDarkKey.self] = newValue }
    }
}

// MARK: - DittoTheme

/**
 * Ditto brand theme for SwiftUI apps.
 *
 * Wrap the root of your app:
 *
 * ```swift
 * @main
 * struct MyApp: App {
 *     var body: some Scene {
 *         WindowGroup {
 *             DittoTheme {              // follows system light/dark
 *                 AppRoot()
 *             }
 *         }
 *     }
 * }
 * ```
 *
 * - `mode`: light, dark, or follow-system (default).
 * - `highContrast`: uses Anvil's high-contrast color tiers (mirrors the web
 *   `light-high-contrast` / `dark-high-contrast` themes). When omitted,
 *   follows the system "Increase Contrast" accessibility setting.
 *
 * Inside, read colors via `@Environment(\.dittoColors)` — e.g.
 * `colors.fillSuccess` — and brightness via `@Environment(\.dittoIsDark)`.
 */
public struct DittoTheme<Content: View>: View {
    private let mode: DittoThemeMode
    private let highContrast: Bool?
    private let content: Content

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast

    public init(
        mode: DittoThemeMode = .system,
        highContrast: Bool? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.mode = mode
        self.highContrast = highContrast
        self.content = content()
    }

    private var tier: AnvilThemeTier {
        let dark = switch mode {
        case .system: systemColorScheme == .dark
        case .light: false
        case .dark: true
        }
        let hc = highContrast ?? (systemColorSchemeContrast == .increased)
        return switch (dark, hc) {
        case (true, true): .darkHighContrast
        case (true, false): .dark
        case (false, true): .lightHighContrast
        case (false, false): .light
        }
    }

    public var body: some View {
        let tier = self.tier
        return content
            .environment(\.dittoColors, anvilSemanticColors(tier: tier))
            .environment(\.dittoIsDark, tier == .dark || tier == .darkHighContrast)
    }
}
