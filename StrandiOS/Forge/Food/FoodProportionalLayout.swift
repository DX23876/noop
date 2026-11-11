#if os(iOS)
import SwiftUI

/// Places its one child at `fraction` of the proposed width: as wide as that, or (for a mark) centred on it.
struct FoodProportionalLayout: Layout {
    var fraction: Double
    var mark = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let x = bounds.width * min(1, max(0, fraction))
        if mark {
            let size = child.sizeThatFits(.unspecified)
            child.place(at: CGPoint(x: bounds.minX + x - size.width / 2, y: bounds.midY), anchor: .leading,
                        proposal: ProposedViewSize(size))
        } else {
            child.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                        proposal: ProposedViewSize(width: x, height: bounds.height))
        }
    }
}
#endif
