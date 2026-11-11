#if os(iOS)
import SwiftUI

/// Lays its views out left to right and wraps to the next line when the row is full, like words in a sentence.
struct DietFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in zip(row.indices, row.xs) {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var indices: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0, y: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
                x = 0
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].xs.append(x)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
            rows[rows.count - 1].width = x - spacing
        }
        return rows
    }
}
#endif
