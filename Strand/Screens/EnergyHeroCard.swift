import SwiftUI
import StrandAnalytics
import StrandDesign

// EnergyHeroCard.swift — the Energy detail screen's own hero.
//
// Not `EnergyCard` with a flag. The two look alike and are not the same card: Today's has three
// figures, is one of a dozen cards competing for a dashboard, and must cost nothing to paint. This
// one splits active energy four ways across a single row, sets the day's total in display type, and
// is the only thing above the fold on a screen the reader opened deliberately. Parameterising one
// view into both would have meant every future change to either arriving with a condition attached.
//
// What they DO share is the mark and the number formatting (`EnergyCompositionMark`,
// `EnergyDisplay`) — the parts where a divergence would be a lie rather than a layout.

/// How much of a day's active energy happened inside a logged session, and how much was the rest of
/// life. Built by applying `EnergyDayRate.trainingFraction` to the summary's own active figure, so
/// the two always sum to it.
struct EnergyActiveBreakdown: Equatable, Sendable {
    let movementKcal: Double
    let trainingKcal: Double

    /// Nil unless the day has both a measured active figure and a five-minute grid to split it by.
    init?(activeKcal: Double?, trainingFraction: Double?) {
        guard let activeKcal, activeKcal.isFinite, activeKcal > 0,
              let trainingFraction, trainingFraction.isFinite else { return nil }
        let clamped = min(1, max(0, trainingFraction))
        self.trainingKcal = activeKcal * clamped
        self.movementKcal = activeKcal * (1 - clamped)
    }
}

struct EnergyHeroCard: View {
    let summary: DailyEnergySummary
    let breakdown: EnergyActiveBreakdown?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NoopCard(tint: StrandPalette.energyResting) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Label("Energy", systemImage: "flame.fill")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(StrandPalette.energyHighlight)
                    Spacer(minLength: 8)
                    confidencePill
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) { mark; headline }
                } else {
                    HStack(spacing: 18) { mark; headline; Spacer(minLength: 0) }
                }

                Divider().overlay(StrandPalette.hairline)
                statStrip

                if let note = qualityNote {
                    Label(note, systemImage: "info.circle")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var mark: some View {
        EnergyCompositionMark(restingKcal: summary.basalBurnedSoFar,
                              activeKcal: summary.activeBurnedSoFar,
                              hasTotal: summary.totalBurnedSoFar != nil)
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(EnergyDisplay.totalText(summary, includesUnit: true))
                .font(StrandFont.heroNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
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
    }

    // MARK: - The four figures

    /// One row where the language fits in one row, a 2×2 grid where it does not.
    ///
    /// The reference layout is four across, and four across is right for "Basal burn / Active /
    /// Daily movement / Training". It is not right for every language this app ships: at ~82 pt a
    /// column, "Tägliche Bewegung" and "Mouvement quotidien" either shrink to unreadable or wrap
    /// into a ragged row, and picking the row layout unconditionally means picking it for English
    /// and hoping. `ViewThatFits` measures the labels that are ACTUALLY on screen and drops to a
    /// grid — same tiles, same order, twice the width each — when they do not fit. Nothing is ever
    /// truncated, and no language is a special case in the code.
    @ViewBuilder private var statStrip: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) { statColumn }
        } else {
            ViewThatFits(in: .horizontal) { statRow; statGrid; statColumn }
        }
    }

    private var statRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 { rowDivider }
                // Natural width, single line: this candidate's ideal size is what ViewThatFits
                // measures, so a cell that stretched or wrapped here would always "fit" and the
                // grid below would be dead code.
                EnergyHeroStat(stat: stat, singleLine: true)
                    .fixedSize(horizontal: true, vertical: false)
                    // Measured at its natural width (fixedSize above, which is what ViewThatFits
                    // reads), then allowed to fill an equal share of the row so the four cells sit
                    // in columns rather than bunched against the left.
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var statGrid: some View {
        VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { start in
                if start > 0 { Divider().overlay(StrandPalette.hairline) }
                HStack(alignment: .top, spacing: 0) {
                    EnergyHeroStat(stat: stats[start])
                    if start + 1 < stats.count {
                        rowDivider
                        EnergyHeroStat(stat: stats[start + 1])
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var statColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                EnergyHeroStat(stat: stat, alignment: .leading)
            }
        }
    }

    private var rowDivider: some View {
        Divider().frame(height: 46).overlay(StrandPalette.hairline).padding(.trailing, 9)
    }

    private var stats: [EnergyHeroStat.Model] {
        var items: [EnergyHeroStat.Model] = [
            .init(label: summary.basalBurnedSoFar == nil ? "Basal / day" : "Basal burn",
                  spoken: summary.basalBurnedSoFar == nil ? String(localized: "Basal / day")
                                                          : String(localized: "Basal burn"),
                  kcal: summary.basalBurnedSoFar ?? summary.estimatedBMR24h,
                  symbol: "bed.double.fill", color: StrandPalette.energyResting,
                  approximate: summary.basalBurnedSoFar == nil,
                  share: share(summary.basalBurnedSoFar)),
            .init(label: "Active", spoken: String(localized: "Active"),
                  kcal: summary.activeBurnedSoFar, symbol: "figure.run",
                  color: StrandPalette.energyActive, approximate: false,
                  share: share(summary.activeBurnedSoFar)),
        ]
        if let breakdown {
            items.append(.init(label: "Daily movement", spoken: String(localized: "Daily movement"),
                               kcal: breakdown.movementKcal,
                               symbol: "figure.walk", color: StrandPalette.energyMovement,
                               approximate: false, share: share(breakdown.movementKcal)))
            items.append(.init(label: "Training", spoken: String(localized: "Training"),
                               kcal: breakdown.trainingKcal,
                               symbol: "dumbbell.fill", color: StrandPalette.energyTraining,
                               approximate: false, share: share(breakdown.trainingKcal)))
        }
        return items
    }

    /// Every share is of the day's TOTAL — one denominator for all four, so basal and active come to
    /// 100 % and the two halves of active come to whatever active is. A share of anything else is
    /// the kind of percentage that survives review and confuses everyone afterwards.
    private func share(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0,
              let total = summary.totalBurnedSoFar, total > 0 else { return nil }
        return value / total
    }

    // MARK: - Chrome

    private var confidencePill: some View {
        HStack(spacing: 5) {
            Circle().fill(EnergyProvenance.confidenceColor(summary.confidence))
                .frame(width: 6, height: 6)
            Text(confidenceLabel)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(StrandPalette.surfaceInset, in: Capsule())
    }

    private var confidenceLabel: LocalizedStringKey {
        switch summary.confidence {
        case .solid:       return "Measured"
        case .building:    return "Partly estimated"
        case .calibrating: return "Estimated"
        }
    }

    /// Same wording, same rules as the Today card — including the one that stops NOOP blaming a
    /// strap that simply has not synced (`EnergyCard.unmeasuredNote`).
    private var qualityNote: LocalizedStringKey? {
        switch summary.source {
        case .profileOnly:
            return EnergyCard.unmeasuredNote(
                base: "No wearable data for today yet — this is your estimated basal rate, not a measurement.",
                strapPaired: strapSync.paired, lastStrapSync: strapSync.lastSync, day: summary.day)
        case .stepsEstimate:
            return EnergyCard.unmeasuredNote(
                base: "Estimated from steps: no device recorded energy today.",
                strapPaired: strapSync.paired, lastStrapSync: strapSync.lastSync, day: summary.day)
        case .loggedActivity:
            return EnergyCard.unmeasuredNote(
                base: "Estimated from your logged sessions and steps: no device recorded energy today.",
                strapPaired: strapSync.paired, lastStrapSync: strapSync.lastSync, day: summary.day)
        case .appleSplit, .strapWornTime, .mixed:
            switch summary.confidence {
            case .solid:       return nil
            case .building:    return "Partly estimated — your device didn't cover the whole day."
            case .calibrating: return "Mostly estimated — very little of today was recorded."
            }
        }
    }

    private var strapSync: (paired: Bool, lastSync: Date?) {
        AppModel.shared?.strapSyncSnapshot ?? (paired: false, lastSync: nil)
    }

    /// "2,400–2,900" — grouped per the reader's locale, joined with an en dash (the range dash).
    private func forecastRange(_ range: ClosedRange<Double>) -> String {
        let low = Int(range.lowerBound.rounded()).formatted(.number.grouping(.automatic))
        let high = Int(range.upperBound.rounded()).formatted(.number.grouping(.automatic))
        return "\(low)–\(high)"
    }

    private var accessibilitySummary: String {
        var parts = [String(localized: "Energy"),
                     EnergyDisplay.totalText(summary, includesUnit: true),
                     String(localized: "total burned so far")]
        for stat in stats {
            if let value = stat.valueText { parts.append("\(stat.spoken): \(value)") }
        }
        return parts.joined(separator: ", ")
    }
}

/// One of the hero's figures: icon tile, label, kcal, and its share of the day.
struct EnergyHeroStat: View {
    struct Model {
        let label: LocalizedStringKey
        /// The same words as `label`, as a String — VoiceOver needs one, and a LocalizedStringKey
        /// cannot be resolved back into text at runtime. Both literals extract to the same key.
        let spoken: String
        let kcal: Double?
        let symbol: String
        let color: Color
        let approximate: Bool
        let share: Double?

        var valueText: String? {
            guard let kcal, kcal.isFinite, kcal >= 0 else { return nil }
            let number = Int(kcal.rounded()).formatted(.number.grouping(.automatic))
            return approximate ? "~\(number) kcal" : "\(number) kcal"
        }

    }

    let stat: Model
    /// True in the four-across candidate, where the cell states its natural width and must not wrap
    /// — see `EnergyHeroCard.statRow`.
    var singleLine = false
    /// Centred in the row and the grid, where each cell owns an equal column; leading in the single
    /// column, where centred text would have nothing to be centred against and would read as ragged.
    var alignment: HorizontalAlignment = .center

    /// Icon and label on one line, the figure and its share on the next.
    ///
    /// The reference layout puts the icon in a tile to the LEFT of the text, which works at four
    /// columns only on a wider canvas: a 402 pt phone leaves ~82 pt per column, and a 30 pt tile
    /// plus its gap takes 36 of them — "2.029 kcal" does not fit in what is left, and the first
    /// build of this card duly rendered "Daily mov…" over "116 k…". The figure is the reason the
    /// card exists, so it gets the full column width and the icon moves up beside its label.
    ///
    /// The share keeps a line of its own, and that is a width decision rather than a style one.
    /// Beside the figure it makes a cell about 95 pt wide; four of those plus their dividers need
    /// ~410 pt, and a 402 pt phone has 338 to give — so the row would fall to the 2×2 grid and the
    /// card would end up TALLER than the line it saved. It is also what the reference layout does,
    /// for the same arithmetic.
    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: stat.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stat.color)
                Text(stat.label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    // Two lines' worth of space whether or not the label needs them: "Daily
                    // movement" wraps where "Aktiv" does not, and without reserved space its
                    // figure sat a line lower than the three beside it. In the single-line
                    // candidate there is nothing to reserve — that layout exists precisely for
                    // the case where every label is short enough not to wrap.
                    .lineLimit(singleLine ? 1 : 2, reservesSpace: !singleLine)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }
            Text(stat.valueText ?? "—")
                .font(StrandFont.captionNumber)
                .foregroundStyle(stat.valueText == nil ? StrandPalette.textTertiary
                                                       : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let share = stat.share {
                Text(verbatim: "\(Int((share * 100).rounded())) %")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: singleLine ? nil : .infinity,
               alignment: alignment == .center ? .center : .leading)
    }
}
