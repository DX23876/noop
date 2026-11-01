#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// Shared building blocks of the redesigned tabs: an inset group of rows, a row with an icon tile, a
/// metric tile with a small trend line, and a status badge. All colours come from `ForgeColor`.

/// A rounded group of rows (iOS inset-grouped look on a Forge card). Rows are separated with
/// `ForgeRowDivider`.
struct ForgeGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .forgeCard(radius: 22, padding: 0)
    }
}

/// The inset hairline between two `ForgeRow`s, aligned with the row titles.
struct ForgeRowDivider: View {
    var body: some View {
        Rectangle().fill(ForgeColor.separator).frame(height: 0.5).padding(.leading, 58)
    }
}

/// One row: coloured icon tile, title with an optional subtitle, an optional value and a chevron.
struct ForgeRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var unit: String? = nil
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let value {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(value).font(ForgeFont.rounded(19, .bold)).foregroundStyle(ForgeColor.text)
                    if let unit { Text(unit).font(.system(size: 11)).foregroundStyle(ForgeColor.secondary) }
                }
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ForgeColor.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A small status word in a capsule: in range (charge colour), off range (effort colour) or neutral.
struct ForgeBadge: View {
    enum Tone { case good, attention, neutral }
    let text: String
    let tone: Tone

    var body: some View {
        let color: Color = switch tone {
        case .good: ForgeColor.chargeInk
        case .attention: ForgeColor.effortInk
        case .neutral: ForgeColor.secondary
        }
        let fill: Color = switch tone {
        case .good: ForgeColor.charge.opacity(0.16)
        case .attention: ForgeColor.effort.opacity(0.18)
        case .neutral: ForgeColor.fill
        }
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(fill))
    }
}

/// A metric tile for two-column grids: label, large value with unit, a trend line and a badge.
struct ForgeMetricTile: View {
    let label: String
    let value: String?
    let unit: String
    var trend: [Double]? = nil
    var tint: Color = ForgeColor.accent
    var badge: (text: String, tone: ForgeBadge.Tone)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(ForgeColor.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "–").font(ForgeFont.rounded(28, .bold)).foregroundStyle(ForgeColor.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if value != nil {
                    Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(ForgeColor.secondary)
                }
            }
            if let trend, trend.count > 1 {
                Sparkline(values: trend, gradient: Gradient(colors: [tint.opacity(0.55), tint]),
                          lineWidth: 1.8, showsArea: true)
                    .frame(height: 30)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: 30)
            }
            if let badge { ForgeBadge(text: badge.text, tone: badge.tone) }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .forgeCard(radius: 22, padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// The hero of a tab under the large title: a small overline and one large answer.
struct ForgeTabHero<Accessory: View>: View {
    let overline: String
    let headline: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(overline).font(.system(size: 15, weight: .medium)).foregroundStyle(ForgeColor.secondary)
            Text(headline).font(.system(size: 28, weight: .bold)).foregroundStyle(ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .padding(.horizontal, 4)
    }
}

extension ForgeTabHero where Accessory == EmptyView {
    init(overline: String, headline: String) {
        self.init(overline: overline, headline: headline, accessory: { EmptyView() })
    }
}
#endif
