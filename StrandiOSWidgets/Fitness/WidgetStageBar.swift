import SwiftUI
import WidgetKit
import StrandDesign

/// A night split into its stages in one bar: deep, REM and light in the sleep colour's three shades.
struct WidgetStageBar: View {
    let deep: Double
    let rem: Double
    let light: Double
    let tint: Color
    let fullColor: Bool

    var body: some View {
        Canvas { context, size in
            let total = deep + rem + light
            guard total > 0 else { return }
            let parts: [(Double, Double)] = [(deep, 1), (rem, 0.6), (light, 0.3)]
            var x: CGFloat = 0
            for (minutes, shade) in parts where minutes > 0 {
                let w = size.width * CGFloat(minutes / total)
                context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                             with: .color((fullColor ? tint : .primary).opacity(shade)))
                x += w
            }
        }
        .clipShape(Capsule())
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
