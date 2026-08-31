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
        // No NavigationStack/toolbar — on macOS sheets a toolbar renders as a
        // large bottom footer bar (and .automatic puts items lower-left).
        // The header row below gives the exact "title + upper-right X" chrome
        // on every platform.
        VStack(spacing: 0) {
            HStack {
                Text("About this data")
                    .font(.headline)
                    .foregroundStyle(colors.foregroundNormal)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(colors.foregroundSubtle)
                        .frame(minWidth: 32, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("queryInfo.close")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(colors.surface)
            Divider()
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
