import Anvil
import SwiftUI

/// An info button that opens a sheet explaining the exact DQL behind a screen
/// element — the teaching touch (these apps teach the SDK). The sheet shows
/// the query in IBM Plex Mono plus a plain-language explanation for people
/// new to the app.
struct QueryInfoButton: View {
    let query: String
    let explanation: String

    @Environment(\.dittoColors) private var colors
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(colors.foregroundSubtle)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About this query")
        .sheet(isPresented: $showSheet) {
            QueryInfoSheet(query: query, explanation: explanation)
                .presentationDetents([.medium, .large])
        }
    }
}

struct QueryInfoSheet: View {
    let query: String
    let explanation: String

    @Environment(\.dittoColors) private var colors
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The DQL behind this")
                            .font(.headline)
                            .foregroundStyle(colors.foregroundNormal)
                        Text(query)
                            .font(.dittoCode(size: 13))
                            .foregroundStyle(colors.codeForeground)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(colors.codeBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("What it does")
                            .font(.headline)
                            .foregroundStyle(colors.foregroundNormal)
                        Text(explanation)
                            .font(.body)
                            .foregroundStyle(colors.foregroundSubtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("""
                    Tip: every query in the app runs against data synced by Ditto — \
                    offline-first, live-updating.
                    """)
                    .font(.callout)
                    .foregroundStyle(colors.foregroundSubtle)
                }
                .padding()
            }
            .background(colors.background)
            .navigationTitle("About this data")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    AnvilButton("Done", variant: .secondary, size: .sm) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    DittoTheme {
        QueryInfoSheet(
            query: "SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false",
            explanation: """
            All non-deleted orders for the selected store. The store filter is exactly \
            the subscription query the benchmark measures at cold start.
            """
        )
    }
}
