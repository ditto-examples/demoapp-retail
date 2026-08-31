import SwiftUI

extension Color {
    /// Opaque color from a 24-bit RGB integer (0xRRGGBB).
    /// Used by the generated Anvil palette; not part of the design API.
    public init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Same color with a new opacity (0...1).
    func withAlpha(_ alpha: Double) -> Color {
        opacity(alpha)
    }
}
