#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The cycle page's phases and what each one tends to mean for mind, exercise and body (tester request,
/// 2026-11). Every line is general, plain and grounded in the sources each card names; the wearer's own
/// numbers come separately, from their nights. Awareness only: nothing here reads as fertility advice.
enum ForgeCyclePhase: String, CaseIterable {
    case period, follicular, shift, luteal

    var title: String {
        switch self {
        case .period: return String(localized: "cycle.period", defaultValue: "Period")
        case .follicular: return String(localized: "Follicular phase")
        case .shift: return String(localized: "Mid-cycle shift")
        case .luteal: return String(localized: "Luteal phase")
        }
    }

    var shortTitle: String {
        switch self {
        case .period: return String(localized: "cycle.period", defaultValue: "Period")
        case .follicular: return String(localized: "cycle.short.follicular", defaultValue: "Follicular")
        case .shift: return String(localized: "cycle.short.shift", defaultValue: "Shift")
        case .luteal: return String(localized: "cycle.short.luteal", defaultValue: "Luteal")
        }
    }

    var color: Color {
        switch self {
        case .period: return ForgeColor.cyclePeriod
        case .follicular: return ForgeColor.cycleFollicular
        case .shift: return ForgeColor.cycleShift
        case .luteal: return ForgeColor.rest
        }
    }
}

/// The three cards a phase shows.
enum ForgeCycleTopic: String, CaseIterable, Identifiable {
    case mind, exercise, body
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mind: return String(localized: "cycle.topic.mind", defaultValue: "Mind")
        case .exercise: return String(localized: "cycle.topic.exercise", defaultValue: "Exercise")
        case .body: return String(localized: "cycle.topic.body", defaultValue: "Body")
        }
    }

    var symbol: String {
        switch self {
        case .mind: return "brain.head.profile"
        case .exercise: return "figure.walk"
        case .body: return "thermometer.medium"
        }
    }

    /// What the card says first, in two or three sentences.
    func summary(_ phase: ForgeCyclePhase) -> String {
        switch (phase, self) {
        case (.period, .mind): return String(localized: "Energy and mood often dip in the first days, and cramps can add to it. This usually lifts within a few days.")
        case (.period, .exercise): return String(localized: "Gentle movement eases period pain for many. On average performance changes little, so if you feel fine, train as planned.")
        case (.period, .body): return String(localized: "Your nights cool back to your lower range. Resting heart rate and HRV drift back toward the usual of your first half.")
        case (.follicular, .mind): return String(localized: "Many people feel steadier in this stretch. How much the cycle moves mood differs a lot from person to person.")
        case (.follicular, .exercise): return String(localized: "Nothing the cycle explains holds you back now. Plan hard sessions around your Charge, not around the calendar.")
        case (.follicular, .body): return String(localized: "Your nights run at your usual low temperature. Resting heart rate and HRV sit at your baseline.")
        case (.shift, .mind): return String(localized: "Most people notice nothing special here. A few feel a short change in energy or mood.")
        case (.shift, .exercise): return String(localized: "No change needed. Train as your recovery allows.")
        case (.shift, .body): return String(localized: "Your nightly temperature has started to rise. This is the shift NOOP reads from your nights.")
        case (.luteal, .mind): return String(localized: "In the days before your period many people feel more irritable, low or tired, and sleep can be lighter. It is common and passes once the period starts.")
        case (.luteal, .exercise): return String(localized: "Studies find only small differences across the cycle, so train by how you feel. You run a little warmer now: drink more when it is hot.")
        case (.luteal, .body): return String(localized: "Your nights run warmer and your heart works a little harder at rest. This is the usual shift of this phase, not a sign of illness.")
        }
    }

    /// The longer read on the card's own page.
    func more(_ phase: ForgeCyclePhase) -> String {
        switch (phase, self) {
        case (.period, .mind): return String(localized: "Warmth, rest and gentle movement help many people with cramps. If pain keeps you from daily life every month, see a doctor.")
        case (.period, .exercise): return String(localized: "Heavy periods can leave you short on iron over time, which shows up as unusual tiredness in training. A blood test tells you.")
        case (.period, .body): return String(localized: "The drop in temperature is the other half of the shift NOOP reads. A new cycle begins on the day you log.")
        case (.follicular, .mind): return String(localized: "Notice what you feel rather than what you expect to feel. Logging mood for a few cycles shows your own pattern.")
        case (.follicular, .exercise): return String(localized: "Training plans built on cycle phases have little support in studies so far. Your recovery each morning is the better guide.")
        case (.follicular, .body): return String(localized: "These nights are the reference that the later rise is measured against.")
        case (.shift, .mind): return String(localized: "Some feel a brief pull in the lower belly around this time. It passes within a day or two.")
        case (.shift, .exercise): return String(localized: "Nothing in the research calls for a different session in these days.")
        case (.shift, .body): return String(localized: "The rise usually follows ovulation by a day or two, so it shows what has already happened rather than what is coming.")
        case (.luteal, .mind): return String(localized: "Breathing exercises, daylight and regular bedtimes help many people through these days. If low mood or irritability gets in the way of work or relationships every month, talk to a doctor: it is treatable.")
        case (.luteal, .exercise): return String(localized: "Hard sessions may feel a touch harder, mostly because your body runs warmer. If they do, keep the volume and take the intensity down a notch. If they feel normal, there is no reason to change your plan.")
        case (.luteal, .body): return String(localized: "Charge reads HRV and resting heart rate against your usual, so it often sits a little lower in these days. That is part of the cycle, not a sign that you trained too much.")
        }
    }

    /// The studies a card stands on, in one plain sentence each.
    func sources(_ phase: ForgeCyclePhase) -> String {
        switch self {
        case .mind:
            return String(localized: "Baker and Lee 2018, Sleep Medicine Clinics: sleep is more disturbed for many in the days before a period. Premenstrual symptoms are common; a severe form affects a few people in a hundred.")
        case .exercise:
            let base = String(localized: "McNulty and colleagues 2020, Sports Medicine: performance differs only slightly across the cycle on average, with large differences between people.")
            guard phase == .period else { return base }
            return base + " " + String(localized: "Armour and colleagues 2019, Cochrane: exercise may ease period pain.")
        case .body:
            return String(localized: "Schmalenberger and colleagues 2019, Journal of Clinical Medicine: HRV is lower in the luteal phase. Skin temperature rises by about 0.3 to 0.5 °C after ovulation.")
        }
    }
}
/// The one-line answer the Mind and Exercise cards lead with: is today a day to push or to go easier? The
/// wearer's own pattern decides when there is one (`CycleTrainingPattern`), else today's Charge does. The
/// phase alone never tells anyone to hold back, since on average it makes little difference.
struct ForgeCyclePush {
    static let learningKey = "noopCycleTrainingLearning"

    let headline: String
    let reason: String
    let tone: Color

    static func make(topic: ForgeCycleTopic, phase: ForgeCyclePhase, charge: Double?,
                     pattern: CycleTrainingPattern.Result?) -> ForgeCyclePush? {
        switch topic {
        case .body: return nil
        case .mind: return mind(phase)
        case .exercise: return exercise(phase, charge: charge, pattern: pattern)
        }
    }

    private static func mind(_ phase: ForgeCyclePhase) -> ForgeCyclePush {
        switch phase {
        case .period:
            return .init(headline: String(localized: "Energy may be lower today"),
                         reason: String(localized: "Common in the first days. Plan what matters for the afternoon."), tone: ForgeColor.cyclePeriod)
        case .follicular:
            return .init(headline: String(localized: "Usually steadier days"),
                         reason: String(localized: "A good stretch for things that need focus."), tone: ForgeColor.cycleFollicular)
        case .shift:
            return .init(headline: String(localized: "Usually nothing to notice"),
                         reason: String(localized: "A few people feel a short change in energy or mood."), tone: ForgeColor.cycleShift)
        case .luteal:
            return .init(headline: String(localized: "Mood and sleep may dip"),
                         reason: String(localized: "Common before a period. Keep evenings calm and bedtimes regular."), tone: ForgeColor.rest)
        }
    }

    private static func patternPhase(_ phase: ForgeCyclePhase) -> CycleTrainingPattern.Phase? {
        switch phase {
        case .period: return .period
        case .follicular: return .follicular
        case .luteal: return .luteal
        case .shift: return nil
        }
    }

    private static func exercise(_ phase: ForgeCyclePhase, charge: Double?, pattern: CycleTrainingPattern.Result?) -> ForgeCyclePush {
        let band = charge.map { ChargeBand.of(score: $0) }
        let chargeText = charge.map { String(localized: "Charge \(Int($0.rounded())).") }
        let verdict = patternPhase(phase).flatMap { p in pattern?.verdict(for: p) }
        if case .harder(let rpe, let drop) = verdict {
            return .init(headline: String(localized: "Take it a bit easier today"),
                         reason: harderReason(rpe: rpe, drop: drop), tone: ForgeColor.effort)
        }
        switch band {
        case .primed?, .peak?:
            let why: String
            if case .easier? = verdict { why = String(localized: "Your sessions in this phase usually feel easier.") }
            else if case .noDifference? = verdict { why = String(localized: "Your cycle makes no clear difference to your training.") }
            else { why = String(localized: "Nothing in your cycle holds you back.") }
            return .init(headline: String(localized: "Good day to push"),
                         reason: [chargeText, why].compactMap { $0 }.joined(separator: " "), tone: ForgeColor.charge)
        case .moderate?:
            return .init(headline: String(localized: "Train as planned"),
                         reason: [chargeText, String(localized: "Keep the hardest sets for a fresher day.")].compactMap { $0 }.joined(separator: " "),
                         tone: ForgeColor.text)
        case .low?, .depleted?:
            return .init(headline: String(localized: "Keep it easy today"),
                         reason: [chargeText, String(localized: "Your body is still recovering.")].compactMap { $0 }.joined(separator: " "),
                         tone: ForgeColor.effort)
        case nil:
            return .init(headline: String(localized: "Train by feel"),
                         reason: String(localized: "No Charge yet today."), tone: ForgeColor.text)
        }
    }

    private static func harderReason(rpe: Double?, drop: Double?) -> String {
        if let rpe, rpe >= CycleTrainingPattern.rpeThreshold {
            let points = rpe.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.activeLocale))
            return String(localized: "In this phase your sessions felt about \(points) points harder in past cycles. Keep the volume, skip the records.")
        }
        let pct = Int(((drop ?? 0) * 100).rounded())
        return String(localized: "In this phase you lifted about \(pct) % less in past cycles. Keep the volume, skip the records.")
    }

    /// The "In your data" line for the Exercise page: the pattern, or how far the learning has come.
    static func patternLine(_ pattern: CycleTrainingPattern.Result?, phase: ForgeCyclePhase) -> String? {
        guard let pattern else { return nil }
        guard let p = patternPhase(phase) else { return nil }
        switch pattern.verdict(for: p) {
        case .learning:
            let progress = pattern.progress
            return String(localized: "Still learning your pattern: \(min(progress.cycles, CycleTrainingPattern.minCycles)) of \(CycleTrainingPattern.minCycles) cycles, \(min(progress.rated, CycleTrainingPattern.minSessionsPerPhase)) of \(CycleTrainingPattern.minSessionsPerPhase) rated sessions in each half. Rate your sessions after training to speed it up.")
        case .harder(let rpe, let drop):
            return harderReason(rpe: rpe, drop: drop)
        case .easier:
            return String(localized: "Your sessions in this phase usually feel easier than in the other half.")
        case .noDifference:
            return String(localized: "Your cycle makes no clear difference to your training.")
        }
    }
}
#endif
