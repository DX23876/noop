import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Being walked into the energy pages
//
// The flow asks exactly what the calculation needs and says why at every stop. What it deliberately
// does NOT do is end on "your requirement is 2 480 kcal". A single figure presented at the end of a
// wizard reads as a measurement of the person, and it is not one — it is one route's answer, and the
// other two routes will disagree with it.
//
// So the last step is the corridor: three numbers, where each came from, and which input moves them
// most. Someone who finishes this flow should be able to say why the numbers differ, which is the
// thing that actually makes a plan survive contact with a bad week.

struct EnergyOnboardingFlow: View {
    @ObservedObject var model: EnergyPlanModel
    let profile: UserProfile
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private var hasBody: Bool {
        model.metrics.value("height", on: model.today) != nil || profile.heightCm > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    // Five steps with no indication of where you are is a flow people abandon in the
                    // middle, because nothing tells them the middle is where they are.
                    progressBar
                    switch step {
                    case 0: whyStep
                    case 1: bodyStep
                    case 2: activityStep
                    case 3: goalStep
                    default: corridorStep
                    }
                }
                .padding(NoopMetrics.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Energy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step >= 4 ? String(localized: "Done") : String(localized: "Next")) {
                        if step >= 4 {
                            EnergyOnboarding.markSeen()
                            onFinished()
                            dismiss()
                        } else {
                            step += 1
                        }
                    }
                }
            }
        }
    }

    private static let stepCount = 5

    private var progressBar: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? StrandPalette.metricCyan
                                        : StrandPalette.hairline)
                    .frame(height: 3)
            }
        }
        .accessibilityLabel(Text("Step \(step + 1) of \(Self.stepCount)"))
    }

    // MARK: - Steps

    private var whyStep: some View {
        stepBody(title: String(localized: "Three routes to one number"),
                 body: String(localized: "How much you burn in a day cannot be measured directly outside a laboratory. Everything else is an estimate by another route.\n\nNOOP takes three. A published formula predicts what a body like yours costs. Your strap records what your days actually looked like. And your intake against your weight change says what you must have burned, whatever any device thought.\n\nThey will not agree. The distance between them is the useful part — it tells you how much confidence the plan deserves."))
    }

    private var bodyStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            stepBody(title: String(localized: "What the formula needs"),
                     body: String(localized: "Height, weight, age and sex. These four are all a basal formula uses — it is a population regression, not a measurement of your metabolism, and it cannot see anything else about you.\n\nIf you also have a body-fat figure, a better formula becomes available: Katch-McArdle works from lean mass, so it can tell two people of the same height and weight apart. It is only better when that figure is good, which is why NOOP offers it rather than switching for you."))
            if !hasBody {
                Text("Your height is not recorded yet. The Body page is where it goes, along with everything else that has a date.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activityStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            stepBody(title: String(localized: "How active is an ordinary day?"),
                     body: String(localized: "The formula multiplies your basal rate by an activity step. These steps are conventions — the ones the literature and every calorie calculator use — and nobody's real life has a multiplier of exactly 1.55.\n\nThis is the input that moves the formula's answer most. One step up or down is worth a few hundred kilocalories a day, which is more than most people's deficit. That sensitivity is exactly why the formula's answer is worth comparing against what your strap recorded rather than trusted alone."))
            VStack(spacing: 0) {
                ForEach(ActivityLevel.allCases, id: \.self) { level in
                    Button { model.activity = level } label: {
                        HStack {
                            Image(systemName: model.activity == level
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.activity == level
                                                 ? StrandPalette.metricCyan
                                                 : StrandPalette.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(activityName(level)).font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(activityDetail(level)).font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Text("×\(level.factor.formatted())")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// What each step means in a day, so the ladder is a description rather than five adjectives.
    private func activityDetail(_ level: ActivityLevel) -> String {
        switch level {
        case .sedentary: return String(localized: "Seated most of the day, little walking")
        case .light:     return String(localized: "Some walking, one or two sessions a week")
        case .moderate:  return String(localized: "On your feet a fair amount, three to five sessions")
        case .high:      return String(localized: "Physical work or training most days")
        case .veryHigh:  return String(localized: "Hard training twice a day, or heavy manual work")
        }
    }

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            stepBody(title: String(localized: "What are you aiming for?"),
                     body: String(localized: "A target rate of change, not a calorie number. The calories follow from it.\n\nThe conversion uses 7 700 kcal per kilogram — the Wishnofsky convention from 1958. It is an approximation and it runs optimistic over months, because a body that has been in a deficit for a while burns a little less than it used to. Once you have logged enough intake and weigh-ins, NOOP replaces it with your own observed figure."))
            Text(rateText).font(StrandFont.number(24))
                .foregroundStyle(StrandPalette.textPrimary)
            Slider(value: $model.targetKgPerWeek, in: -1...0.5, step: 0.05)
            HStack {
                Text("−1,0 kg/week").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("+0,5 kg/week").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var corridorStep: some View {
        let corridor = model.corridor(profile: profile)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Where that leaves you")
                .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            row(String(localized: "Formula predicts"), corridor.formulaKcal)
            row(String(localized: "Your wearable recorded"), corridor.measuredKcal)
            row(String(localized: "Intake and weight imply"), corridor.balanceKcal)
            if let spread = corridor.spreadKcal {
                Text("They span \(Int(spread.rounded())) kcal a day. Plan against the middle, and let the routes that are still missing fill in — the balance figure in particular needs a couple of weeks before it says anything.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Only one route can answer so far. The others fill in as your strap records days and you log what you eat — and the comparison is what this screen is for.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing here is a measurement of your metabolism. Each number names where it came from, so you can tell which one to doubt when they disagree.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

    private func stepBody(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(body).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: Double?) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value.map { "\(Int($0.rounded())) kcal" } ?? String(localized: "not yet"))
                .font(StrandFont.number(20))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
    }

    private var rateText: String {
        let rate = model.targetKgPerWeek
        if abs(rate) < 0.025 { return String(localized: "Hold weight") }
        let value = abs(rate).formatted(.number.precision(.fractionLength(2)))
        return rate < 0 ? String(localized: "Lose \(value) kg/week")
                        : String(localized: "Gain \(value) kg/week")
    }

    private func activityName(_ level: ActivityLevel) -> String {
        switch level {
        case .sedentary: return String(localized: "Desk")
        case .light:     return String(localized: "Light")
        case .moderate:  return String(localized: "Moderate")
        case .high:      return String(localized: "High")
        case .veryHigh:  return String(localized: "Very high")
        }
    }
}

/// Whether the guided introduction has run. Shown once, then reachable from the screen itself.
enum EnergyOnboarding {
    private static let key = "energy.onboarding.seen"
    static var hasSeen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}
