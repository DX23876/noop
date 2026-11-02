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
    /// The denser iOS Settings look: smaller icon tile, regular-weight title.
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            // Settings rows keep the iOS Settings tile (white glyph on a coloured square); list rows use the
            // prototype's tinted circle with a coloured glyph.
            Group {
                if compact {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(tint.opacity(0.16)))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16, weight: compact ? .regular : .semibold))
                    .foregroundStyle(ForgeColor.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: compact ? 12 : 13)).foregroundStyle(ForgeColor.secondary)
                        .lineLimit(2)
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
        .padding(.vertical, compact ? 8 : 11)
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
    /// Day bars (Monday first) instead of a trend line; the last non-zero bar is drawn full strength.
    var bars: [Double]? = nil
    /// Small labels under the chart (weekday initials), as in the prototype's tiles.
    var axisLabels: [String]? = nil

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
            if let bars, bars.contains(where: { $0 > 0 }) {
                let top = max(bars.max() ?? 1, 1)
                let lastIndex = bars.lastIndex(where: { $0 > 0 })
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(tint.opacity(i == lastIndex ? 1 : 0.45))
                            .frame(height: max(3, 30 * v / top))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 30, alignment: .bottom)
                .accessibilityHidden(true)
            } else if let trend, trend.count > 1 {
                Sparkline(values: trend, gradient: Gradient(colors: [tint.opacity(0.55), tint]),
                          lineWidth: 1.8, showsArea: true)
                    .frame(height: 30)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: 30)
            }
            if let axisLabels, (bars != nil || (trend?.count ?? 0) > 1) {
                HStack(spacing: 0) {
                    ForEach(Array(axisLabels.enumerated()), id: \.offset) { _, label in
                        Text(label).font(.system(size: 10)).foregroundStyle(ForgeColor.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
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
/// Which way a factor moved a score, as the prototype writes it: "↑ raises", "↓ lowers", "– neutral".
struct ForgeDirection: View {
    let delta: Int

    var body: some View {
        let (icon, word, color): (String, String, Color) = delta > 0
            ? ("arrow.up", String(localized: "raises"), ForgeColor.chargeInk)
            : delta < 0 ? ("arrow.down", String(localized: "lowers"), ForgeColor.effortInk)
                        : ("minus", String(localized: "neutral"), ForgeColor.secondary)
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(word).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// Heart-rate zones of a session as one bar with each zone's name and minutes underneath, from the zone
/// shares the session stored.
struct ForgeZoneBar: View {
    let percents: [Double]
    let minutes: Double

    var body: some View {
        let total = max(percents.reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(Array(percents.enumerated()), id: \.offset) { i, p in
                        Capsule().fill(StrandPalette.hrZoneColor(i + 1))
                            .frame(width: max(4, (geo.size.width - 12) * p / total))
                    }
                }
            }
            .frame(height: 7)
            HStack(spacing: 4) {
                ForEach(Array(percents.enumerated()), id: \.offset) { i, p in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(LiveHeartRateStyle.zoneName(i + 1)).lineLimit(1).minimumScaleFactor(0.6)
                        Text("\(Int((minutes * p / total).rounded()))")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(ForgeColor.secondary)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate zones"))
    }
}

/// A night's stage shares as one strip in the stage colours (deep, light, REM, awake).
struct ForgeStageStrip: View {
    let deep: Double
    let rem: Double
    let light: Double
    let awake: Double

    var body: some View {
        let parts: [(Double, Color)] = [(deep, StrandPalette.sleepStageColor(.deep)),
                                        (light, StrandPalette.sleepStageColor(.light)),
                                        (rem, StrandPalette.sleepStageColor(.rem)),
                                        (awake, StrandPalette.sleepStageColor(.awake))]
        let total = max(parts.map(\.0).reduce(0, +), 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(part.1)
                            .frame(width: max(3, (geo.size.width - 6) * part.0 / total))
                    }
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
/// Charge, Effort and Rest of one day as three small concentric rings (outer to inner), each filled to
/// its stored value on the 0 to 100 axis.
struct ForgeMiniRings: View {
    let charge: Double?
    let effort: Double?
    let rest: Double?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = side * 0.12
            ZStack {
                ring(charge, ForgeColor.charge, inset: line / 2, line: line)
                ring(effort, ForgeColor.effort, inset: line * 1.6, line: line)
                ring(rest, ForgeColor.rest, inset: line * 2.7, line: line)
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }

    private func ring(_ value: Double?, _ color: Color, inset: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: line)
            Circle().trim(from: 0, to: max(0, min(1, (value ?? 0) / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
    }
}
#endif
