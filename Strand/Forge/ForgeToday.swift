import Foundation

/// Pure readouts for the redesigned Today hero (2026-11). Every value here is a re-expression of a number
/// another screen already shows: the Effort target band is `CoupledView.optimalStrainRange`, the bedtime is
/// the wind-down planner's own wake time minus its sleep need. Nothing is stored and nothing new is derived.
///
/// Analysis migration required: no. Presentation only.
enum ForgeToday {

    /// Today's Effort target on the STORED 0–100 axis, from the same Charge bands Coupled uses.
    /// `optimalStrainRange` speaks the 0–21 axis, so its bounds are carried over with the same ×100/21 the
    /// stored scale uses everywhere else.
    static func effortTargetStored(charge: Double?) -> ClosedRange<Double>? {
        guard let band = CoupledView.optimalStrainRange(recovery: charge) else { return nil }
        return (Double(band.lowerBound) * 100 / 21)...(Double(band.upperBound) * 100 / 21)
    }

    enum TargetPosition: Equatable { case below, inside, above }

    static func position(effortStored: Double, target: ClosedRange<Double>) -> TargetPosition {
        if effortStored < target.lowerBound { return .below }
        if effortStored > target.upperBound { return .above }
        return .inside
    }

    /// "14 to 18" on the 0–21 scale, "67 to 86" on the 0–100 one: whole numbers, the user's own scale.
    static func targetText(_ target: ClosedRange<Double>, scale: EffortScale) -> (low: String, high: String) {
        let lo = UnitFormatter.effortValue(target.lowerBound, scale: scale)
        let hi = UnitFormatter.effortValue(target.upperBound, scale: scale)
        return (String(Int(lo.rounded())), String(Int(hi.rounded())))
    }

    /// Effort as the hero ring prints it: a whole number on the 0–100 scale, one decimal on 0–21, so a
    /// sentence or a card can never show 84.9 beside a ring that reads 85.
    static func effortText(_ stored: Double, scale: EffortScale) -> String {
        let value = UnitFormatter.effortValue(stored, scale: scale)
        return scale == .whoop
            ? String(format: "%.1f", locale: AppLanguage.activeLocale, value)
            : String(Int(value.rounded()))
    }

    /// The one sentence under the rings. It only compares two numbers the rings already show, so it never
    /// claims more than they do; with no Effort or no Charge there is nothing to compare and it says nothing.
    static func summary(effortStored: Double?, charge: Double?, scale: EffortScale) -> String? {
        guard let effortStored, let target = effortTargetStored(charge: charge) else { return nil }
        let value = effortText(effortStored, scale: scale)
        let t = targetText(target, scale: scale)
        switch position(effortStored: effortStored, target: target) {
        case .below:
            return String(localized: "Effort is \(value), below today's target of \(t.low) to \(t.high).")
        case .inside:
            return String(localized: "Effort is \(value), inside today's target of \(t.low) to \(t.high).")
        case .above:
            return String(localized: "Effort is \(value), above today's target of \(t.low) to \(t.high).")
        }
    }

    /// Rest in one word, with the same thresholds and words the Overview dashboard uses for its Rest tile,
    /// so the two designs never describe the same night differently.
    static func restWord(_ score: Double) -> String {
        score >= 80 ? String(localized: "Good") : score >= 60 ? String(localized: "Fair") : String(localized: "Low")
    }

    /// Tonight's bedtime from the wind-down planner's own inputs: tomorrow's wake time minus the sleep
    /// need. The planner owns both values (Alarms and Sleep edit them), so every screen that names a
    /// bedtime reads this one function.
    static func bedtime(now: Date, calendar: Calendar = .current,
                        wakeMinutes: (Int) -> Int, sleepNeedMinutes: Int) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        let weekday = calendar.component(.weekday, from: tomorrow)
        let wake = tomorrow.addingTimeInterval(TimeInterval(wakeMinutes(weekday) * 60))
        return wake.addingTimeInterval(TimeInterval(-sleepNeedMinutes * 60))
    }

    /// `bedtime` with the planner's stored wake times and sleep need.
    @MainActor static func plannedBedtime(now: Date) -> Date? {
        bedtime(now: now, wakeMinutes: { WindDownNudge.wakeMinutes(forWeekday: $0) },
                sleepNeedMinutes: WindDownNudge.sleepNeedMinutes)
    }
}
