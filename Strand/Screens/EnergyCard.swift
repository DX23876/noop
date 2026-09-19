import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Energy (Stufe 2) — one card, not six tiles
//
// The individual figures (basal, active, total, projection, maintenance) would make five more Key
// Metric tiles, and five tiles that only ever move together are five ways to say one thing. This is
// the one card, with everything else on the detail screen behind it.
//
// The card's job is to be HONEST about how much of the day was actually measured. `EnergyEngine`
// hands over a coverage figure and a confidence tier derived from data that already exists — a
// three-hour Apple Watch day lands near 12% and must not render like a fully measured one. That is
// why the caption is not decoration: it is the difference between a number and a guess.

struct EnergyCard: View {
    let summary: DailyEnergySummary
    /// Whether a strap is paired at all, and when one last completed a sync. Together they are the
    /// difference between "nothing measured today" and "the strap has not handed today over yet" —
    /// two states the card used to report with one sentence, which was a lie to anyone wearing a strap.
    let strapPaired: Bool
    let lastStrapSync: Date?

    /// The pair is resolved from the app's live state by DEFAULT rather than threaded through the
    /// three call sites, because all three sit in view hierarchies that deliberately do not observe
    /// `LiveState`: it publishes at ~1 Hz while a strap streams, and Today explicitly avoids an
    /// `@EnvironmentObject live` for exactly that reason. Reading a snapshot here subscribes to
    /// nothing. Tests and previews pass the pair explicitly.
    init(summary: DailyEnergySummary, strapSync: (paired: Bool, lastSync: Date?)? = nil) {
        self.summary = summary
        let resolved = strapSync ?? AppModel.shared?.strapSyncSnapshot
        self.strapPaired = resolved?.paired ?? false
        self.lastStrapSync = resolved?.lastSync
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NoopCard(tint: StrandPalette.energyResting) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Label("Energy", systemImage: "flame.fill")
                        .strandOverlineLabel(color: StrandPalette.energyHighlight)
                    Spacer(minLength: 8)
                    confidencePill
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) { energyMark; headline }
                } else {
                    HStack(spacing: 18) { energyMark; headline }
                }

                Divider().overlay(StrandPalette.hairline)
                statStrip

                if let note = qualityNote {
                    Label(note, systemImage: "info.circle")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var energyMark: some View {
        EnergyCompositionMark(restingKcal: summary.basalBurnedSoFar,
                              activeKcal: summary.activeBurnedSoFar,
                              hasTotal: summary.totalBurnedSoFar != nil)
            .frame(width: 104, height: 104)
            .accessibilityHidden(true)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headlineTotal)
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .minimumScaleFactor(0.72)
            Text("total burned so far")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            if let range = summary.projectedRangeKcal {
                Text("Forecast range: \(forecastRange(range)) kcal")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineTotal: String {
        EnergyDisplay.totalText(summary, includesUnit: true)
    }

    private var statStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { statItems }
            VStack(alignment: .leading, spacing: 10) { statItems }
        }
    }

    @ViewBuilder private var statItems: some View {
        EnergyStat(label: restingLabel, value: kcal(summary.basalBurnedSoFar ?? summary.estimatedBMR24h),
                   symbol: "bed.double.fill", color: StrandPalette.energyResting,
                   approximate: summary.basalBurnedSoFar == nil)
        EnergyStat(label: "Active", value: kcal(summary.activeBurnedSoFar),
                   symbol: "figure.run", color: StrandPalette.energyActive)
        EnergyStat(label: "Projected", value: kcal(summary.projectedTotalBurn),
                   symbol: "sun.max.fill", color: StrandPalette.energyHighlight, approximate: true)
    }

    private var restingLabel: LocalizedStringKey {
        summary.basalBurnedSoFar == nil ? "Basal / day" : "Resting"
    }

    @ViewBuilder private var confidencePill: some View {
        HStack(spacing: 5) {
            Circle().fill(confidenceColor).frame(width: 6, height: 6)
            Text(confidenceLabel)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(StrandPalette.surfaceInset, in: Capsule())
    }

    private var confidenceLabel: LocalizedStringKey {
        switch summary.confidence {
        case .solid: return "Measured"
        case .building: return "Partly estimated"
        case .calibrating: return "Estimated"
        }
    }

    private var confidenceColor: Color {
        switch summary.confidence {
        case .solid: return StrandPalette.statusPositive
        case .building: return StrandPalette.statusWarning
        case .calibrating: return StrandPalette.textTertiary
        }
    }

    /// What the card says about its own reliability. `nil` on a solidly measured day — a caption that
    /// appears on every day teaches people to stop reading it.
    private var qualityNote: LocalizedStringKey? {
        switch summary.source {
        case .profileOnly:
            return Self.unmeasuredNote(
                base: "No wearable data for today yet — this is your estimated basal rate, not a measurement.",
                strapPaired: strapPaired, lastStrapSync: lastStrapSync, day: summary.day)
        case .stepsEstimate:
            return Self.unmeasuredNote(
                base: "Estimated from steps: no device recorded energy today.",
                strapPaired: strapPaired, lastStrapSync: lastStrapSync, day: summary.day)
        case .loggedActivity:
            return Self.unmeasuredNote(
                base: "Estimated from your logged sessions and steps: no device recorded energy today.",
                strapPaired: strapPaired, lastStrapSync: lastStrapSync, day: summary.day)
        case .appleSplit, .strapWornTime, .mixed:
            switch summary.confidence {
            case .solid:       return nil
            case .building:    return "Partly estimated — your device didn't cover the whole day."
            case .calibrating: return "Mostly estimated — very little of today was recorded."
            }
        }
    }

    /// The caption for a day nothing measured — and the one place that decides whether NOOP may blame
    /// the absence on there being no device.
    ///
    /// "No device recorded energy today" is a claim about the world. It is true for someone with no
    /// strap; it is false for someone wearing one that simply has not offloaded yet, and telling them
    /// their strap recorded nothing sends them looking for a fault that does not exist. Where a strap
    /// IS paired and has not synced since this day began, the card says that instead — the thing it
    /// can actually attribute.
    ///
    /// Static and parameterised so the wording is testable without a view, a strap or a clock.
    static func unmeasuredNote(base: LocalizedStringKey, strapPaired: Bool, lastStrapSync: Date?,
                               day: String, now: Date = Date(),
                               calendar: Calendar = .current) -> LocalizedStringKey {
        guard strapPaired else { return base }
        // Only today can be waiting on a sync. A past day with no energy is finished being measured.
        guard day == Repository.localDayKey(now) else { return base }
        guard let lastStrapSync, lastStrapSync >= calendar.startOfDay(for: now) else {
            return "Your strap hasn't synced today yet — this is an estimate until it does."
        }
        return base
    }

    private func kcal(_ value: Double?) -> String? {
        value.map { "\(Int($0.rounded()).formatted(.number.grouping(.automatic))) kcal" }
    }

    /// "2,400–2,900" — grouped per the reader's locale, joined with an en dash (the range dash).
    private func forecastRange(_ range: ClosedRange<Double>) -> String {
        let low = Int(range.lowerBound.rounded()).formatted(.number.grouping(.automatic))
        let high = Int(range.upperBound.rounded()).formatted(.number.grouping(.automatic))
        return "\(low)–\(high)"
    }

    private var accessibilitySummary: String {
        var parts = [String(localized: "Energy"), headlineTotal, String(localized: "total burned so far")]
        if let active = kcal(summary.activeBurnedSoFar) {
            parts.append("\(String(localized: "Active")): \(active)")
        }
        if let resting = kcal(summary.basalBurnedSoFar ?? summary.estimatedBMR24h) {
            parts.append("\(String(localized: "Resting")): \(resting)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Shared presentation contract for every Today surface that shows the canonical daily total.
/// Keeping the approximation marker and rounding here prevents the compact Calories tile from
/// drifting back to Apple active energy or the legacy `activeKcalEst` value.
enum EnergyDisplay {
    static func totalText(_ summary: DailyEnergySummary?, includesUnit: Bool = false) -> String {
        guard let summary, let total = summary.totalBurnedSoFar,
              total.isFinite, total >= 0 else { return "—" }
        let number = Int(total.rounded()).formatted(.number.grouping(.automatic))
        let approximate = summary.source == .appleSplit ? number : "~\(number)"
        return includesUnit ? "\(approximate) kcal" : approximate
    }
}

struct EnergyCompositionMark: View {
    let restingKcal: Double?
    let activeKcal: Double?
    let hasTotal: Bool

    static func fractions(resting: Double?, active: Double?) -> (resting: Double, active: Double)? {
        let resting = max(0, resting ?? 0)
        let active = max(0, active ?? 0)
        let total = resting + active
        guard total > 0 else { return nil }
        return (resting / total, active / total)
    }

    private var fractions: (resting: Double, active: Double)? {
        Self.fractions(resting: restingKcal, active: activeKcal)
    }

    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.energyTrack, style: .init(lineWidth: 10, lineCap: .round))
            if hasTotal, let fractions {
                Circle()
                    .trim(from: 0, to: fractions.resting)
                    .stroke(StrandPalette.energyResting,
                            style: .init(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                if fractions.active > 0 {
                    Circle()
                        .trim(from: fractions.resting, to: 1)
                        .stroke(StrandPalette.energyActive,
                                style: .init(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            Circle()
                .fill(StrandPalette.energyHighlight.opacity(0.12))
                .frame(width: 62, height: 62)
            Image(systemName: "flame.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LinearGradient(gradient: StrandPalette.energyGradient,
                                                startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct EnergyStat: View {
    let label: LocalizedStringKey
    let value: String?
    let symbol: String
    let color: Color
    var approximate = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Text(displayValue)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayValue: String {
        guard let value else { return "—" }
        return approximate ? "~\(value)" : value
    }
}

private extension Label where Title == Text, Icon == Image {
    func strandOverlineLabel(color: Color) -> some View {
        self
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
