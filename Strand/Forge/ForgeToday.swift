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

    /// The hour of the day-cycle scene a light page shows: the night hours map to the nearest bright scene.
    static func lightPageSceneHour(_ hour: Int) -> Int {
        switch hour {
        case 0...5: return 6
        case 19...23: return 18
        default: return hour
        }
    }

    /// The 25 % and 75 % marks of a series (linear between ranks), nil under 7 values.
    static func middleHalf(_ values: [Double]) -> (low: Double, high: Double)? {
        DriverUsualRange.middleHalf(values)
    }

    /// A value and a range on one 0 to 100 track (`DriverUsualRange.place`, shared with Android's core).
    static func place(_ value: Double, low: Double, high: Double) -> (position: Double, band: ClosedRange<Double>) {
        DriverUsualRange.place(value, low: low, high: high)
    }

    /// Mean of the days that have a value, nil when none has (a week's Effort as the weekly report reads it).
    static func weekMean(_ values: [Double?]) -> Double? {
        let xs = values.compactMap { $0 }
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Rest in one word, with the same thresholds and words the Overview dashboard uses for its Rest tile,
    /// so the two designs never describe the same night differently.
    /// Rest's word, in the bands the Sleep screen and Android use (owner, 2026-11-11: the top band is "Optimal").
    static func restWord(_ score: Double) -> String {
        switch score {
        case ..<50: return String(localized: "Poor")
        case ..<70: return String(localized: "Fair")
        case ..<85: return String(localized: "Good")
        default: return String(localized: "Optimal")
        }
    }

    /// Tonight's bedtime from the wind-down planner's own inputs: tomorrow's wake time minus the sleep
    /// need. The wake times are set in Alarms; the need is the one the Sleep tab states
    /// (`SleepModel.currentNeedMin`), which `WindDownNudge.adoptSleepNeed` keeps the planner in step with.
    /// Every screen that names a bedtime reads this one function.
    static func bedtime(now: Date, calendar: Calendar = .current,
                        wakeMinutes: (Int) -> Int, sleepNeedMinutes: Int) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        let weekday = calendar.component(.weekday, from: tomorrow)
        let wake = tomorrow.addingTimeInterval(TimeInterval(wakeMinutes(weekday) * 60))
        return wake.addingTimeInterval(TimeInterval(-sleepNeedMinutes * 60))
    }

    /// When the evening report and the coach's evening recap may appear: two hours before tonight's planned
    /// bedtime, never before 19:00. Without a bedtime that evening, 19:00.
    static func eveningStart(now: Date, bedtime: Date?, calendar: Calendar = .current) -> Date {
        let seven = calendar.date(bySettingHour: ForgeCoachNotes.eveningStartHour, minute: 0, second: 0, of: now) ?? now
        guard let bedtime else { return seven }
        return max(seven, bedtime.addingTimeInterval(-2 * 3600))
    }

    /// `bedtime` with the planner's stored wake times and sleep need.
    @MainActor static func plannedBedtime(now: Date) -> Date? {
        bedtime(now: now, wakeMinutes: { WindDownNudge.wakeMinutes(forWeekday: $0) },
                sleepNeedMinutes: WindDownNudge.sleepNeedMinutes)
    }

    // MARK: - Charge drivers in the reader's language

    /// `ChargeDrivers` writes its read-outs in fixed English ("15.3 br/min", "-0.2 C vs baseline") because
    /// tests and the coach read them. These turn one into what a screen prints: the reader's decimal mark,
    /// plain units, "usual" instead of "baseline", and a skin-temperature deviation in the reader's unit
    /// (the engine's text is Celsius-only by contract, so a Fahrenheit reader used to see °C here). The
    /// deviation is converted from the engine's one-decimal figure, the same `skinTempDeviationFigure` the
    /// classic Charge breakdown uses.
    static func driverValue(_ text: String, locale: Locale = AppLanguage.activeLocale,
                            temperatureUnit: TemperatureUnit = readerTemperatureUnit) -> String {
        if text.hasSuffix(" C vs baseline"),
           let celsius = Double(text.dropLast(" C vs baseline".count)) {
            let figure = localizedDecimals(
                ChargeBreakdownFormat.skinTempDeviationFigure(celsius, unit: temperatureUnit), locale: locale)
            return String(localized: "\(figure) vs usual")
        }
        return localizedDecimals(text, locale: locale).replacingOccurrences(of: "br/min", with: "/min")
    }

    /// The reader's temperature unit, resolved the way every screen resolves it (explicit override when
    /// set, else from the unit system). Read from the store because this is not a View.
    static var readerTemperatureUnit: TemperatureUnit {
        let defaults = UserDefaults.standard
        let system = UnitSystem(rawValue: defaults.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        return UnitPrefs.resolveTemperature(system: system,
                                            override: defaults.string(forKey: UnitPrefs.temperatureKey) ?? "")
    }

    /// "75 ms baseline" as "usually 75 ms".
    static func driverUsual(_ text: String, locale: Locale = AppLanguage.activeLocale) -> String {
        let value = localizedDecimals(text.replacingOccurrences(of: " baseline", with: ""), locale: locale)
            .replacingOccurrences(of: "br/min", with: "/min")
        return String(localized: "usually \(value)")
    }

    private static func localizedDecimals(_ text: String, locale: Locale) -> String {
        let mark = locale.decimalSeparator ?? "."
        guard mark != "." else { return text }
        return text.replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1\(mark)$2", options: .regularExpression)
    }
}

