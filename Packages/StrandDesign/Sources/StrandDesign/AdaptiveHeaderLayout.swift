import SwiftUI

/// Keeps a date/title and its controls inside the offered width. When the controls expand,
/// they move below the title and wrap as needed without recreating their stateful views.
public struct AdaptiveHeaderLayout: Layout {
    private let spacing: CGFloat

    public init(spacing: CGFloat = NoopMetrics.space1) {
        self.spacing = spacing
    }

    struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    static func arrange(title: CGSize, controls: [CGSize], width: CGFloat,
                        spacing: CGFloat) -> Arrangement {
        let controlsWidth = controls.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, controls.count - 1)) * spacing
        let gap = controls.isEmpty ? 0 : spacing
        if title.width + gap + controlsWidth <= width {
            var frames = [CGRect(origin: .zero, size: title)]
            var x = width - controlsWidth
            for control in controls {
                frames.append(CGRect(x: x, y: 0, width: control.width, height: control.height))
                x += control.width + spacing
            }
            return Arrangement(frames: frames,
                               size: CGSize(width: width, height: max(title.height, controls.map(\.height).max() ?? 0)))
        }

        var frames = [CGRect(origin: .zero, size: title)]
        var y = title.height + spacing
        var row: [CGSize] = []
        var rowWidth: CGFloat = 0
        func finishRow() {
            guard !row.isEmpty else { return }
            var x = width - rowWidth
            for control in row {
                frames.append(CGRect(x: x, y: y, width: control.width, height: control.height))
                x += control.width + spacing
            }
            y += (row.map(\.height).max() ?? 0) + spacing
            row = []
            rowWidth = 0
        }
        for control in controls {
            let added = control.width + (row.isEmpty ? 0 : spacing)
            if !row.isEmpty, rowWidth + added > width { finishRow() }
            rowWidth += control.width + (row.isEmpty ? 0 : spacing)
            row.append(control)
        }
        finishRow()
        return Arrangement(frames: frames, size: CGSize(width: width, height: y - spacing))
    }

    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        guard let title = subviews.first else { return Arrangement(frames: [], size: .zero) }
        let controls = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
        let controlsWidth = controls.reduce(0) { $0 + $1.width } + CGFloat(controls.count) * spacing
        let width = max(0, proposal.width ?? (title.sizeThatFits(.unspecified).width + controlsWidth))
        var titleSize = title.sizeThatFits(ProposedViewSize(width: max(0, width - controlsWidth), height: nil))
        if titleSize.width + controlsWidth > width {
            titleSize = title.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        return Self.arrange(title: titleSize, controls: controls, width: width, spacing: spacing)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
