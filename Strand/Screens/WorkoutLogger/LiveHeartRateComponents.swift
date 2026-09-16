import SwiftUI
import StrandAnalytics
import StrandDesign

/// Live heart-rate building blocks shared by the cardio live screen and the strength logger, so both show
/// heart rate, its zone and the effort built up the same way instead of two lookalike copies drifting.
enum LiveHeartRateStyle {
    static func tint(zone: Int) -> Color {
        zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
    }

    static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }

    /// "Zone 3 · Aerobic", or "Below Zone 1".
    static func zoneTitle(_ zone: Int) -> String {
        zone >= 1 ? String(localized: "Zone \(zone) · \(zoneName(zone))") : String(localized: "Below Zone 1")
    }
}

/// The heart-rate number in its zone colour, counting up to each new value.
struct LiveHeartRateValue: View {
    let bpm: Int?
    let zone: Int
    let size: CGFloat

    var body: some View {
        let tint = LiveHeartRateStyle.tint(zone: zone)
        if let bpm {
            CountUpText(value: Double(bpm), format: { "\(Int($0.rounded()))" },
                        font: StrandFont.rounded(size, weight: .semibold), color: tint)
        } else {
            Text("—").font(StrandFont.rounded(size, weight: .semibold)).foregroundStyle(tint)
        }
    }
}

/// The five zones as a rail, the current one lit, an optional target outlined.
struct HeartRateZoneRail: View {
    let zone: Int
    var targetZone: Int?
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(1...5, id: \.self) { z in
                let active = z == zone
                let color = StrandPalette.hrZoneColor(z)
                RoundedRectangle(cornerRadius: compact ? 5 : 8, style: .continuous)
                    .fill(active ? color : color.opacity(0.18))
                    .frame(height: compact ? (active ? 22 : 16) : (active ? 44 : 34))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 5 : 8, style: .continuous)
                            .strokeBorder(active ? color : StrandPalette.hairline, lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 5 : 8, style: .continuous)
                            .strokeBorder(z == targetZone ? StrandPalette.accent : .clear, lineWidth: 3)
                    )
                    .overlay {
                        if !compact {
                            Text("Z\(z)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(active ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LiveHeartRateStyle.zoneTitle(zone)))
    }
}

/// Effort built up so far on the wearer's chosen scale, with its intensity word.
struct LiveEffortReadout: View {
    /// NOOP's 0–100 strain, or nil when there is not enough heart rate yet.
    let strain: Double?
    let size: CGFloat
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    var body: some View {
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        let display = UnitFormatter.effortValue(strain ?? 0, scale: scale)
        let maxValue = scale == .whoop ? 21.0 : 100.0
        let fraction = min(max(display / maxValue, 0), 1)
        VStack(spacing: 2) {
            if strain == nil {
                Text("—").font(StrandFont.rounded(size, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            } else {
                CountUpText(value: display, format: { String(format: "%.1f", $0) },
                            font: StrandFont.rounded(size, weight: .semibold), color: StrandPalette.textPrimary)
            }
            if strain != nil {
                Text(StrainGauge.stateLabel(forFraction: fraction))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effort"))
        .accessibilityValue(Text(strain == nil ? "—" : String(format: "%.1f", display)))
    }
}
