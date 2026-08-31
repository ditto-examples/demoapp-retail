import SwiftUI

/// A minimal wrapping ("flow") layout — chips wrap to the next line instead
/// of clipping when the window narrows (macOS) or on compact iPad splits.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? 0, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, position) in rows.positions {
            guard let size = rows.sizes[index] else { continue }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(size)
            )
        }
    }

    private struct Arrangement {
        var positions: [(Int, CGPoint)] = []
        var sizes: [Int: CGSize] = [:]
        var height: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        var result = Arrangement()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            result.positions.append((index, CGPoint(x: x, y: y)))
            result.sizes[index] = size
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        result.height = y + rowHeight
        return result
    }
}
