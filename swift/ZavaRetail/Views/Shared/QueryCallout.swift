import SwiftUI
import Anvil

/// The teaching touch: a tappable disclosure that shows the exact DQL a
/// screen element just ran, in IBM Plex Mono. These apps teach the SDK, so
/// the query text is never hidden behind a helper name.
struct QueryCallout: View {
    let query: String
    @Environment(\.dittoColors) private var colors
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("DQL")
                        .font(.dittoCode(size: 11))
                }
                .foregroundStyle(colors.foregroundSubtle)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(query)
                    .font(.dittoCode(size: 11))
                    .foregroundStyle(colors.codeForeground)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.codeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
    }
}

#Preview {
    DittoTheme {
        QueryCallout(query: "SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false")
            .padding()
    }
}
