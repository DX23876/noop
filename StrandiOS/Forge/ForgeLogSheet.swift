#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// What the redesign's Log sheet can open. The shell maps each to a screen that already exists, so the
/// sheet only gathers the entry points that were spread over the quick-action menu, Today and More.
enum ForgeLogChoice: Hashable {
    case coachWrite, coachSpeak
    case workout, weight, journal, drink, energy, sleep, labMarkers, breathe, liveHeartRate
}

/// The redesign's "Log" sheet: logging through the coach first (when it is on), then the direct forms.
struct ForgeLogSheet: View {
    let onPick: (ForgeLogChoice) -> Void
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

    private struct Item: Identifiable {
        let choice: ForgeLogChoice
        let title: String
        let systemImage: String
        let tint: Color
        var id: ForgeLogChoice { choice }
    }

    private var direct: [Item] {
        [
            Item(choice: .workout, title: String(localized: "Training"), systemImage: "figure.run", tint: ForgeColor.effort),
            Item(choice: .weight, title: String(localized: "Weight"), systemImage: "scalemass.fill", tint: ForgeColor.charge),
            Item(choice: .journal, title: String(localized: "Journal"), systemImage: "book.fill", tint: ForgeColor.accent),
            Item(choice: .drink, title: String(localized: "Drink"), systemImage: "drop.fill", tint: .blue),
            Item(choice: .energy, title: String(localized: "Food and energy"), systemImage: "fork.knife", tint: ForgeColor.effort),
            Item(choice: .sleep, title: String(localized: "Sleep"), systemImage: "moon.fill", tint: ForgeColor.rest),
            Item(choice: .labMarkers, title: String(localized: "Lab values"), systemImage: "testtube.2", tint: ForgeColor.rest),
            Item(choice: .breathe, title: String(localized: "Breathe"), systemImage: "wind", tint: ForgeColor.charge),
            Item(choice: .liveHeartRate, title: String(localized: "Live heart rate"), systemImage: "heart.fill", tint: .red),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if coachFeatureEnabled {
                    Text("Log with the coach").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                    HStack(spacing: 22) {
                        coachButton(.coachWrite, "Write", "text.bubble.fill")
                        coachButton(.coachSpeak, "Speak", "mic.fill")
                        Spacer()
                    }
                }
                Text("Log yourself").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                FlowRows(spacing: 8) {
                    ForEach(direct) { item in
                        Button { onPick(item.choice) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(item.tint)
                                Text(item.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(ForgeColor.text)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .background(Capsule().fill(ForgeColor.fill))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .padding(.top, 8)
        }
        .background(ForgeColor.canvas.ignoresSafeArea())
    }

    private func coachButton(_ choice: ForgeLogChoice, _ title: LocalizedStringKey, _ image: String) -> some View {
        Button { onPick(choice) } label: {
            VStack(spacing: 6) {
                Image(systemName: image)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ForgeColor.onAccent)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(ForgeColor.accent))
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(ForgeColor.text)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Lays chips out left to right and wraps them onto further rows.
struct FlowRows: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
