import Anvil
import SwiftUI

/// Shared pagination bar (Edge Studio's PaginationControls pattern, Anvil
/// styling): total count, page-size menu, prev/next with "page X of Y".
/// The DQL behind it is `… ORDER BY … LIMIT <pageSize> OFFSET <offset>` —
/// DQL supports both clauses; ints from our own controls are interpolated.
struct PaginationBar: View {
    let totalCount: Int
    @Binding var page: Int
    @Binding var pageSize: Int
    let pageSizes: [Int]
    let onPageChange: () -> Void

    @Environment(\.dittoColors) private var colors

    var pageCount: Int {
        max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(totalCount.formatted()) total")
                .font(.dittoCode(size: 12))
                .foregroundStyle(colors.foregroundSubtle)

            Spacer()

            Menu("Show \(pageSize)") {
                ForEach(pageSizes, id: \.self) { size in
                    Button("\(size) per page") {
                        page = 1
                        pageSize = size
                        onPageChange()
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(colors.foregroundSubtle)

            Button {
                page = max(1, page - 1)
                onPageChange()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(page <= 1)
            .foregroundStyle(page <= 1 ? colors.foregroundDisabled : colors.foregroundNormal)
            .accessibilityIdentifier("PaginationPrevButton")

            Text("\(page) of \(pageCount)")
                .font(.dittoCode(size: 12))
                .foregroundStyle(colors.foregroundNormal)
                .accessibilityIdentifier("PaginationPageIndicator")

            Button {
                page = min(pageCount, page + 1)
                onPageChange()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(page >= pageCount)
            .foregroundStyle(page >= pageCount ? colors.foregroundDisabled : colors.foregroundNormal)
            .accessibilityIdentifier("PaginationNextButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

#Preview {
    DittoTheme {
        PaginationBar(
            totalCount: 24921,
            page: .constant(2),
            pageSize: .constant(50),
            pageSizes: [25, 50, 100],
            onPageChange: {}
        )
    }
}
