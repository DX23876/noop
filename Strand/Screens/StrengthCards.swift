import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

// MARK: - The cards the Strength screen gained
//
// Three additions, each of which answers a question the screen could not answer before, and each built
// from the same rule the rest of this lane follows: a MEASURED figure carries the card, an estimate is
// labelled as one, and nothing is compared against a number NOOP invented.
//
//   • Records    — the heaviest set, the best session, the best set in each rep band. All measured, all
//                  dated. The estimated 1RM sits among them wearing the word "est.".
//   • Balance    — push against pull, upper against lower, quads against hips. Counting, with the
//                  wearer's OWN usual ratio drawn behind the bar instead of a textbook target.
//   • Bodyweight — the volume a calisthenics day actually moved, priced from the wearer's own weigh-ins
//                  and kept beside barbell tonnage rather than added to it.

// MARK: - A two-sided bar

/// One axis drawn as a single bar filled from both ends.
///
/// The wearer's own usual band is drawn BEHIND the fill as a hatched region, exactly as
/// `TypicalRangeBar` does for the muscle rows — same visual grammar, so "the shaded part is what is
/// normal for you" only has to be learned once on this screen.
struct StrengthBalanceBar: View {
    /// Share of the axis' sets on side A, 0…1.
    let shareA: Double
    /// The wearer's usual share for side A, when there is enough history for one.
    let typicalShareA: ClosedRange<Double>?
    // The two sides must be TELLABLE APART at a glance. They were `effortColor` and `accent`, which are
    // both amber in this palette, so a 13:0 week rendered as one continuous orange bar — indisting-
    // uishable from a balanced one. Cyan against amber is the same pairing the rest of the app uses for
    // two-quantity comparisons.
    var colorA: Color = StrandPalette.effortColor
    var colorB: Color = StrandPalette.metricCyan
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(colorB.opacity(0.30))
                if let typicalShareA {
                    let lo = min(max(typicalShareA.lowerBound, 0), 1)
                    let hi = min(max(typicalShareA.upperBound, 0), 1)
                    DiagonalHatch(spacing: 4)
                        .stroke(StrandPalette.textTertiary.opacity(0.55), lineWidth: 1)
                        .frame(width: max(width * (hi - lo), 2))
                        .offset(x: width * lo)
                        .clipShape(Capsule())
                }
                Capsule()
                    .fill(LinearGradient(colors: [colorA.opacity(0.85), colorA],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * min(max(shareA, 0), 1))
                    .animation(NoopMotion.value, value: shareA)
                // The midpoint, so "even" is readable without doing arithmetic on two numbers.
                Rectangle()
                    .fill(StrandPalette.surfaceBase.opacity(0.9))
                    .frame(width: 1.5)
                    .offset(x: width / 2)
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Records

extension StrengthView {

    /// The measured bests for the selected movement, under its chart.
    ///
    /// A strip rather than a card of its own: these are facts ABOUT the line above them, and separating
    /// them would invite reading the estimate and the measurements as two different subjects.
    @ViewBuilder
    var recordsStrip: some View {
        if let records = model.records, !records.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricAmber)
                        .accessibilityHidden(true)
                    Text("Your bests").strandOverline()
                    Spacer(minLength: 0)
                    if let stood = recordAge(records) {
                        Text(stood)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let heaviest = records.heaviestSet {
                            recordChip(String(localized: "Heaviest set"),
                                       value: setText(heaviest),
                                       day: heaviest.day, tint: StrandPalette.effortColor)
                        }
                        ForEach(StrengthRepBand.allCases, id: \.self) { band in
                            if let record = records.bestByRepBand[band] {
                                recordChip(String(localized: "Best \(band.label) reps"),
                                           value: "\(record.value.formatted(.number.precision(.fractionLength(1)))) kg",
                                           day: record.day, tint: StrandPalette.accent)
                            }
                        }
                        if let volume = records.bestSessionVolume {
                            recordChip(String(localized: "Best session"),
                                       value: volumeText(volume.value),
                                       day: volume.day, tint: StrandPalette.metricCyan)
                        }
                        if let estimate = records.bestE1RM {
                            recordChip(String(localized: "Best 1RM · est."),
                                       value: "\(estimate.value.formatted(.number.precision(.fractionLength(1)))) kg",
                                       day: estimate.day, tint: StrandPalette.textSecondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    /// One record, as a small card. Value first, because that is what is being looked for.
    private func recordChip(_ label: String, value: String, day: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            Text(value)
                .font(StrandFont.number(17))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Text(Self.shortDay(day))
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minWidth: 104, alignment: .leading)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(Self.shortDay(day))")
    }

    private func setText(_ record: StrengthRecordPoint) -> String {
        let weight = record.value.formatted(.number.precision(.fractionLength(1)))
        guard let reps = record.reps else { return "\(weight) kg" }
        return "\(weight) kg × \(reps)"
    }

    /// How long the heaviest set has stood. A FACT about the record, never phrased as a plateau — how
    /// long a best should stand depends on the block someone is running, which this screen cannot know.
    private func recordAge(_ records: ExerciseRecords) -> String? {
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970), offsetSec: 0)
        guard let days = StrengthProgress.daysSinceHeaviestSet(records, today: today), days >= 28 else {
            return nil
        }
        return days >= 56
            ? String(localized: "top set unbeaten for \(days / 7) weeks")
            : String(localized: "top set unbeaten for \(days) days")
    }

    static func shortDay(_ day: String) -> String {
        guard let date = WeightSeries.date(forDay: day) else { return day }
        return date.formatted(Date.FormatStyle().day().month(.abbreviated).year(.twoDigits))
    }

    // MARK: - Balance

    /// Push against pull, upper against lower, quads against hips — for the selected week.
    @ViewBuilder
    var balanceCard: some View {
        let readings = model.balance.filter { $0.total > 0 }
        if !readings.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    SectionHeader("Balance", overline: "Counted sets")
                    Spacer(minLength: 8)
                    infoButton(.balance)
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(readings, id: \.axis) { reading in balanceRow(reading) }
                        if let offAxis = offAxisText {
                            Text(offAxis)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Sides are added up from each set's primary muscle — there is no list of \"push exercises\": a set lands where its exercise's primary muscle sits. The hatched part is YOUR usual ratio over the last eight weeks; NOOP ships no target ratio, because there is no measured one to ship.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// What the axes did NOT cover this week.
    ///
    /// A set reaches a side through its primary muscle, and the sides are explicit lists — so a
    /// deadlift filed under lower back, or a set of crunches, is on no axis at all. Saying so is the
    /// alternative to two worse options: sweeping those sets onto a side they do not belong to, or
    /// letting the reader assume the bars cover the whole week.
    private var offAxisText: String? {
        let off = StrengthBalance.setsOffAxis(setsByMuscle: model.week.setsByMuscle)
        guard off.sets > 0 else { return nil }
        let names = off.groups.map { Self.groupLabel($0) }.joined(separator: ", ")
        return String(localized: "\(off.sets) sets are on none of these axes (\(names)) — a deadlift filed under lower back sits outside push and pull, and is not counted as either.")
    }

    /// A muscle group's display name. `HevyMuscleGroup.label` is deliberately locale-STABLE — it is a
    /// storage key — so the words are produced here, where the compiler can extract them.
    static func groupLabel(_ group: HevyMuscleGroup) -> String {
        switch group {
        case .abdominals: return String(localized: "Abdominals")
        case .shoulders:  return String(localized: "Shoulders")
        case .biceps:     return String(localized: "Biceps")
        case .triceps:    return String(localized: "Triceps")
        case .forearms:   return String(localized: "Forearms")
        case .quadriceps: return String(localized: "Quadriceps")
        case .hamstrings: return String(localized: "Hamstrings")
        case .calves:     return String(localized: "Calves")
        case .glutes:     return String(localized: "Glutes")
        case .abductors:  return String(localized: "Abductors")
        case .adductors:  return String(localized: "Adductors")
        case .lats:       return String(localized: "Lats")
        case .upperBack:  return String(localized: "Upper back")
        case .traps:      return String(localized: "Traps")
        case .lowerBack:  return String(localized: "Lower back")
        case .chest:      return String(localized: "Chest")
        case .neck:       return String(localized: "Neck")
        case .cardio:     return String(localized: "Cardio")
        case .fullBody:   return String(localized: "Full body")
        case .other:      return String(localized: "Other")
        }
    }

    private func balanceRow(_ reading: StrengthBalance.Reading) -> some View {
        let labels = reading.axis.sideLabels
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: Self.sideLabel(labels.a))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(reading.setsA)")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.effortColor)
                Spacer(minLength: 8)
                Text("\(reading.setsB)")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.metricCyan)
                Text(verbatim: Self.sideLabel(labels.b))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            StrengthBalanceBar(shareA: reading.shareA ?? 0.5,
                               typicalShareA: typicalShare(for: reading.axis))
            HStack(spacing: 6) {
                Text(ratioText(reading))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let usual = usualRatioText(for: reading.axis) {
                    Text(usual)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(balanceAccessibility(reading))
    }

    /// The display name for one side of an axis.
    ///
    /// A switch over literals rather than `LocalizedStringKey(runtimeString)`: a key built at runtime is
    /// invisible to the compiler's string extraction, so the catalog would never gain an entry and the
    /// word would stay English in every language. `StrengthBalance.Axis` deliberately returns
    /// locale-STABLE keys — grouping keys, not display text — and this is where they become words.
    static func sideLabel(_ key: String) -> String {
        switch key {
        case "Push":              return String(localized: "Push")
        case "Pull":              return String(localized: "Pull")
        case "Upper body":        return String(localized: "Upper body")
        case "Lower body":        return String(localized: "Lower body")
        case "Quads":             return String(localized: "Quads")
        case "Hips & hamstrings": return String(localized: "Hips & hamstrings")
        default:                  return key
        }
    }

    /// The usual RATIO band, converted to the share the bar is drawn in: r sets on A per set on B means
    /// A holds r/(1+r) of the axis.
    private func typicalShare(for axis: StrengthBalance.Axis) -> ClosedRange<Double>? {
        guard let band = model.typicalRatios[axis] else { return nil }
        let lo = band.lowerBound / (1 + band.lowerBound)
        let hi = band.upperBound / (1 + band.upperBound)
        guard hi > lo else { return (max(0, lo - 0.01))...(min(1, hi + 0.01)) }
        return lo...hi
    }

    private func ratioText(_ reading: StrengthBalance.Reading) -> String {
        let labels = reading.axis.sideLabels
        guard let ratio = reading.ratio else {
            let missing = reading.setsA == 0 ? Self.sideLabel(labels.a) : Self.sideLabel(labels.b)
            return String(localized: "no \(missing.lowercased()) sets this week")
        }
        return String(format: "%.2f : 1", ratio)
    }

    /// "· your usual 1.10–1.40", or a single figure when the quartiles coincide.
    ///
    /// A steady lifter's p25 and p75 genuinely land on the same value, and "2.30–2.30" reads as a range
    /// that is not one — the muscle rows solved this the same way.
    private func usualRatioText(for axis: StrengthBalance.Axis) -> String? {
        guard let band = model.typicalRatios[axis] else { return nil }
        if abs(band.upperBound - band.lowerBound) < 0.005 {
            return String(format: String(localized: "· your usual %.2f"), band.lowerBound)
        }
        return String(format: String(localized: "· your usual %.2f–%.2f"),
                      band.lowerBound, band.upperBound)
    }

    private func balanceAccessibility(_ reading: StrengthBalance.Reading) -> String {
        let labels = reading.axis.sideLabels
        var text = "\(labels.a) \(reading.setsA) sets, \(labels.b) \(reading.setsB) sets"
        if let ratio = reading.ratio { text += String(format: ", ratio %.2f to 1", ratio) }
        if let band = model.typicalRatios[reading.axis] {
            text += String(format: ", your usual %.2f to %.2f", band.lowerBound, band.upperBound)
        }
        return text
    }
}
