import Anvil
import SwiftUI

/// Pulsing placeholder block ("ghost") shown while a screen waits for its
/// first data after a store switch — cards keep their shape and the animation
/// tells the user data is being loaded, instead of rendering the previous
/// store's stale rows.
struct SkeletonBox: View {
    var height: CGFloat = 18
    var cornerRadius: CGFloat = 6

    @Environment(\.dittoColors) private var colors
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(colors.surfaceSecondary)
            .frame(height: height)
            .opacity(pulse ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// A stack of ghost rows matching a list's silhouette.
struct SkeletonRows: View {
    var count = 6

    var body: some View {
        VStack(spacing: 14) {
            ForEach(0 ..< count, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonBox(height: 16)
                        .frame(maxWidth: .infinity)
                    SkeletonBox(height: 16)
                        .frame(width: 80)
                }
            }
        }
        .padding()
    }
}

/// A ghost KPI card matching the dashboard grid cells.
struct SkeletonCard: View {
    var body: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBox(height: 12).frame(width: 90)
                SkeletonBox(height: 28).frame(maxWidth: 160)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

#Preview {
    DittoTheme {
        SkeletonRows()
            .padding()
    }
}
