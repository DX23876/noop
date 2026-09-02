import SwiftUI

// MARK: - Today surfaces

/// The visual surface used by Today-only cards. It deliberately lives beside the global component
/// system instead of changing `NoopCard`: the Today refresh can therefore evolve without silently
/// restyling cards on Sleep, Health, Trends, or Settings.
public struct TodayCardSurface: View {
    private let tint: Color?
    private let cornerRadius: CGFloat
    private let surfaceOpacity: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(tint: Color? = nil,
                cornerRadius: CGFloat = NoopMetrics.cardRadius,
                surfaceOpacity: Double = 1) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let opacity = reduceTransparency ? 1 : max(0, min(1, surfaceOpacity))

        shape
            .fill(StrandPalette.surfaceRaised.opacity(opacity))
            .overlay {
                if let tint {
                    shape.fill(tint.opacity((colorScheme == .dark ? 0.075 : 0.045) * opacity))
                }
            }
            .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.18 : 0.075),
                radius: colorScheme == .dark ? 12 : 10,
                x: 0,
                y: colorScheme == .dark ? 6 : 4
            )
    }
}

// MARK: - Today metric tile

/// A compact, modern Today metric tile: a pastel icon disc, strong value hierarchy, an optional
/// progress track, and the existing trend. Callers continue to own all values, routes, order, and state.
public struct TodayMetricTile<Accessory: View>: View {
    private let label: Text
    private let systemImage: String
    private let value: String
    private let unit: String
    private let caption: String?
    private let tint: Color
    private let progress: Double?
    private let reservesProgressSpace: Bool
    private let delta: String?
    private let deltaColor: Color
    private let sparkline: [Double]?
    private let sparkColor: Color
    private let sparklineHeight: CGFloat?
    private let dense: Bool
    private let surfaceOpacity: Double
    @ViewBuilder private let accessory: () -> Accessory

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var regularValueSize: CGFloat = 26
    @ScaledMetric(relativeTo: .title3) private var denseValueSize: CGFloat = 22

    public init(label: Text,
                systemImage: String,
                value: String,
                unit: String = "",
                caption: String? = nil,
                tint: Color,
                progress: Double? = nil,
                reservesProgressSpace: Bool = false,
                delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil,
                sparkColor: Color? = nil,
                sparklineHeight: CGFloat? = nil,
                dense: Bool = false,
                surfaceOpacity: Double = 1,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.label = label
        self.systemImage = systemImage
        self.value = value
        self.unit = unit
        self.caption = caption
        self.tint = tint
        self.progress = progress
        self.reservesProgressSpace = reservesProgressSpace
        self.delta = delta
        self.deltaColor = deltaColor
        self.sparkline = sparkline
        self.sparkColor = sparkColor ?? tint
        self.sparklineHeight = sparklineHeight
        self.dense = dense
        self.surfaceOpacity = surfaceOpacity
        self.accessory = accessory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: dense ? 5 : 6) {
            HStack(alignment: .center, spacing: dense ? 6 : 8) {
                ZStack {
                    Circle().fill(tint.opacity(0.13))
                    Image(systemName: systemImage)
                        .font(.system(size: dense ? 11 : 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: dense ? 26 : 30, height: dense ? 26 : 30)
                .accessibilityHidden(true)

                label
                    .font(dynamicTypeSize.isAccessibilitySize
                          ? StrandFont.overline
                          : StrandFont.overlineScaled(dense ? 9 : 10))
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)
                accessory()
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(StrandFont.number(dense ? denseValueSize : regularValueSize))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                if !unit.isEmpty {
                    Text(unit)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let delta { TrendChip(text: delta, color: deltaColor) }
            }

            if let caption {
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.78)
            }

            if progress != nil || reservesProgressSpace {
                if let progress {
                    GeometryReader { proxy in
                        let fraction = max(0, min(1, progress))
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
                            Capsule(style: .continuous)
                                .fill(tint.gradient)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(height: dense ? 5 : 6)
                    .accessibilityHidden(true)
                } else {
                    Color.clear.frame(height: dense ? 5 : 6).accessibilityHidden(true)
                }
            }

            #if !os(watchOS)
            if let sparklineHeight {
                if let sparkline, sparkline.count > 1 {
                    Sparkline(
                        values: sparkline,
                        gradient: Gradient(colors: [sparkColor.opacity(0.42), sparkColor])
                    )
                    .frame(height: sparklineHeight)
                    .accessibilityHidden(true)
                } else {
                    Color.clear.frame(height: sparklineHeight).accessibilityHidden(true)
                }
            } else if let sparkline, sparkline.count > 1 {
                Sparkline(
                    values: sparkline,
                    gradient: Gradient(colors: [sparkColor.opacity(0.42), sparkColor])
                )
                .frame(height: dense ? 18 : 22)
                .accessibilityHidden(true)
            }
            #endif
        }
        .padding(.horizontal, dense ? 12 : 14)
        .padding(.vertical, dense ? 11 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TodayCardSurface(tint: tint, cornerRadius: NoopMetrics.groupedRadius,
                                     surfaceOpacity: surfaceOpacity))
        .frame(minHeight: NoopMetrics.tileHeight, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

public extension TodayMetricTile where Accessory == EmptyView {
    init(label: Text,
         systemImage: String,
         value: String,
         unit: String = "",
         caption: String? = nil,
         tint: Color,
         progress: Double? = nil,
         reservesProgressSpace: Bool = false,
         delta: String? = nil,
         deltaColor: Color = StrandPalette.textTertiary,
         sparkline: [Double]? = nil,
         sparkColor: Color? = nil,
         sparklineHeight: CGFloat? = nil,
         dense: Bool = false,
         surfaceOpacity: Double = 1) {
        self.init(
            label: label,
            systemImage: systemImage,
            value: value,
            unit: unit,
            caption: caption,
            tint: tint,
            progress: progress,
            reservesProgressSpace: reservesProgressSpace,
            delta: delta,
            deltaColor: deltaColor,
            sparkline: sparkline,
            sparkColor: sparkColor,
            sparklineHeight: sparklineHeight,
            dense: dense,
            surfaceOpacity: surfaceOpacity,
            accessory: { EmptyView() }
        )
    }
}

// MARK: - Today dashboard row

/// The shared visual label for a dashboard link. Navigation and secondary buttons remain outside this
/// component, keeping the existing independent hit targets and behavior intact.
public struct TodayDashboardRow: View {
    private let systemImage: String
    private let title: String
    private let subtitle: String
    private let value: String
    private let tint: Color
    private let progress: Double?
    private let isPlaceholder: Bool

    public init(systemImage: String,
                title: String,
                subtitle: String,
                value: String,
                tint: Color,
                progress: Double? = nil,
                isPlaceholder: Bool = false) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.tint = tint
        self.progress = progress
        self.isPlaceholder = isPlaceholder
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.13))
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0, min(1, progress)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .font(StrandFont.rounded(18, weight: .semibold))
                    .foregroundStyle(isPlaceholder ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
