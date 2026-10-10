import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport
import StrandDesign
import SemanticMemory

// AICoachEngine context builder, the plain-text data summary every turn sends.
// Split out of AICoach.swift unchanged; `AICoachEngine` itself lives there.

extension AICoachEngine {
    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    /// The Effort-axis instruction for the model, or nil when the wearer reads NOOP's native axis and
    /// there is nothing to convert.
    ///
    /// Effort is CANONICALLY 0–100 everywhere the model touches it: this context's day lines and
    /// averages, `target_effort` in the tool schema, `PlanProposal.contextSummary()`, the
    /// `EffortFeasibility` corrections. That must not change — the model has to reason and call tools on
    /// one axis, and converting its inputs would have it pass a 0–21 figure into a 0–100 parameter and
    /// prescribe a rest day while believing it asked for a hard session.
    ///
    /// What was wrong is the OUTPUT: prose. `PlanProposal.summary(effortScale:)` converts the structured
    /// target, but a coach writing "push to about 63 today" was still quoting a number that does not
    /// exist on the axis the wearer's rings show. So the split is stated to the model directly: read and
    /// call on 0–100, quote on their axis.
    ///
    /// Emitted ONLY for the non-native axis. On the default `.hundred` the conversion is the identity, so
    /// the note would be pure tokens — and every existing install's context stays byte-identical.
    ///
    /// This is an INSTRUCTION, not a guarantee: unlike the structured summary, nothing enforces it. It is
    /// the strongest available lever on prose, and it belongs in the context rather than in
    /// `defaultSystemPrompt` because that prompt is user-editable — an instruction there would miss every
    /// wearer who has customised it.
    nonisolated static func effortAxisNote(scale: EffortScale) -> String? {
        guard scale == .whoop else { return nil }
        let max = UnitFormatter.effortScaleMax(scale)
        let example = UnitFormatter.effortWithScale(63, scale: scale)
        return "EFFORT AXIS — this user's app displays Effort on the WHOOP-style 0–\(max) axis, not "
            + "NOOP's native 0–100. Every effort figure below, and every target_effort you pass to a "
            + "tool, is on the 0–100 axis and MUST stay there: reason and call tools in 0–100. But when "
            + "you quote an effort number back to them in your reply, convert it — multiply by "
            + "\(UnitFormatter.effortScaleFactor), one decimal, and name the axis. An effort of 63 is "
            + "written \"\(example)\" to them. Never show them a raw 0–100 effort figure; that number "
            + "does not exist on the axis they read."
    }

    func buildContext(includeGoals: Bool = true) -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = [clockLine(), "", "USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        // Profile + goal (NOOP Forge): the same values the app's HR zones and calorie math use, so the
        // coach can prescribe zones/loads for THIS user. Consent-gated like the rest — buildContext()
        // is only reached with data access on.
        let profile = ProfileStore()
        var profileParts = ["age \(profile.age)", profile.sex,
                            "\(Int(profile.weightKg.rounded())) kg",
                            "\(Int(profile.heightCm.rounded())) cm",
                            "HRmax \(profile.hrMax) bpm"]
        lines.append("Profile: " + profileParts.joined(separator: ", "))
        // The goal as a REAL goal: weeks remaining, required change, phase, and the safety verdict —
        // not the bare sentence the old free-text field could only offer.
        if includeGoals, let goalsBlock = goalsBlock(profile: profile) { lines.append(goalsBlock) }

        guard !days.isEmpty else {
            // Keep the profile/goal line (already appended) so the coach can still personalise zones
            // and advice while there's no wearable history yet.
            lines.append("No wearable data is available yet. Acknowledge this and give general, "
                         + "encouraging guidance while inviting the user to sync their device so future "
                         + "advice can reference real numbers.")
            return lines.joined(separator: "\n")
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        if let axisNote = Self.effortAxisNote(scale: UnitPrefs.currentEffortScale()) {
            lines.append("")
            lines.append(axisNote)
        }
        lines.append("")
        lines.append("Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), "
                     + "deep/REM/light(h), eff(%), HRV(ms), RHR(bpm). A dash means NOT MEASURED, not zero:")
        for d in recent {
            lines.append("  " + dayLine(d))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  charge: \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { activeEnergyByDay[$0.day] }))kcal/day")
        if let display = vo2maxDisplay, let headline = display.primary {
            let source = headline.segment == Repository.appleHealthSource
                ? "Apple Watch, measured \(headline.day)" : "NOOP weekly estimate, not a lab test"
            lines.append(String(format: "VO2max: %.1f ml/kg/min (%@)", headline.value, source))
            if let apple = display.appleLatest {
                lines.append(String(format: "Apple Watch VO2max last measured %.1f ml/kg/min on %@",
                                    apple.value, apple.day))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// A lower-detail core snapshot for a tool-less model. It has a current daily summary and rolling
    /// averages but deliberately omits the 14-day, line-by-line table. The question router promotes to
    /// `buildContext()` only for a recent change/trend question.
    func buildCompactContext() -> String {
        let days = repo.days
        var lines: [String] = [clockLine(), "", "USER BIOMETRIC SNAPSHOT (derived local summary):"]
        let profile = ProfileStore()
        lines.append("Profile: age \(profile.age), \(profile.sex), \(Int(profile.weightKg.rounded())) kg, "
                     + "\(Int(profile.heightCm.rounded())) cm, HRmax \(profile.hrMax) bpm")
        guard !days.isEmpty else {
            lines.append("No wearable data is available yet. Do not invent a trend or a recovery score.")
            return lines.joined(separator: "\n")
        }
        if let axisNote = Self.effortAxisNote(scale: UnitPrefs.currentEffortScale()) {
            lines.append(axisNote)
        }
        if let latest = days.last {
            lines.append("Latest recorded day: " + dayLine(latest))
        }
        let last7 = Array(days.suffix(7))
        lines.append("7-day averages: charge \(avgInt(last7.compactMap { $0.recovery })), "
                     + "effort \(avgOne(last7.compactMap { $0.strain })), "
                     + "sleep \(avgSleepHours(last7))h, HRV \(avgInt(last7.compactMap { $0.avgHrv })) ms, "
                     + "RHR \(avgInt(last7.compactMap { $0.restingHr.map(Double.init) })) bpm.")
        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6, days: Int = 30) async -> String {
        let window = max(1, min(days, 3_650))
        let rows = await repo.workoutRows(days: window) // newest first
        guard !rows.isEmpty else { return "Workout history: none recorded in the last \(window) days." }
        // Distances are quoted to the coach in the unit the wearer reads them in. Since upstream split
        // body measurements from exercise distance, that is the DISTANCE choice, not the body one.
        let bodySystem = UnitSystem(
            rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let distanceSystem = UnitPrefs.resolveDistance(
            system: bodySystem,
            override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        var lines: [String] = []
        if let mostRecent = rows.first {
            let n = daysAgo(mostRecent.startTs)
            let ago = n <= 0 ? "today" : (n == 1 ? "1 day ago" : "\(n) days ago")
            lines.append("Last trained: \(ago) (\(mostRecent.sport)).")
        }
        let oldest = rows.last.map { dateString($0.startTs) } ?? "—"
        let newest = rows.first.map { dateString($0.startTs) } ?? "—"
        lines.append("WORKOUT HISTORY: \(rows.count) sessions, \(oldest) → \(newest), searched \(window) days.")

        var sportCountByName: [String: Int] = [:]
        for row in rows {
            sportCountByName[row.sport, default: 0] += 1
        }
        var sportCounts: [(name: String, count: Int)] = []
        for (name, count) in sportCountByName {
            sportCounts.append((name: name, count: count))
        }
        sportCounts.sort { left, right in
            if left.count == right.count { return left.name < right.name }
            return left.count > right.count
        }
        if !sportCounts.isEmpty {
            lines.append("Sports: " + sportCounts.prefix(12)
                .map { "\($0.name) \($0.count)" }
                .joined(separator: ", "))
        }
        var sourceCountByLabel: [String: Int] = [:]
        for row in rows {
            sourceCountByLabel[CoachLocalSourceLabel.label(row.source), default: 0] += 1
        }
        var sourceCounts: [(label: String, count: Int)] = []
        for (label, count) in sourceCountByLabel {
            sourceCounts.append((label: label, count: count))
        }
        sourceCounts.sort { left, right in left.label < right.label }
        if !sourceCounts.isEmpty {
            lines.append("Local sources: " + sourceCounts
                .map { "\($0.label) \($0.count)" }
                .joined(separator: ", "))
        }
        // The quoted sessions' own resting rates, for the ones that recorded no energy. Bounded by
        // the sessions actually quoted, so this is one small read rather than a history-wide one.
        let quoted = Array(rows.prefix(limit))
        let profileStore = ProfileStore()
        let analyticsProfile = Repository.analyticsProfile(profileStore)
        var restingHrByDay: [String: Double] = [:]
        var peakMETByDay: [String: Double] = [:]
        if let oldest = quoted.map(\.startTs).min(), let newest = quoted.map(\.startTs).max() {
            let fromDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(oldest)))
            let toDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(newest)))
            restingHrByDay = await repo.restingHrByDay(fromDay: fromDay, toDay: toDay)
            peakMETByDay = await repo.energyPeakMETByDay(fromDay: fromDay, toDay: toDay)
        }
        let strapByKey = await repo.strapSessionEnergy(for: quoted)

        lines.append("Newest sessions:")
        for w in quoted {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            // Estimated where nothing recorded it — a lifting session the coach reads as costing
            // nothing is worse than one it reads as costing roughly this much. The provenance goes
            // with it: a bare figure in a prompt becomes a measurement the moment it is quoted back.
            let energy = WorkoutEnergyDisplay.resolve(w, profile: analyticsProfile,
                                                      hrMax: Double(profileStore.hrMax),
                                                      restingHrByDay: restingHrByDay,
                                                      strapKcalByKey: strapByKey,
                                                      peakMETByDay: peakMETByDay)
            if let spoken = WorkoutEnergyDisplay.spoken(energy, averageHR: w.avgHr) {
                parts.append(spoken)
            }
            if let dist = w.distanceM {
                parts.append(UnitFormatter.distanceFromMeters(dist, system: distanceSystem))
            }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Body measurements and the energy corridor, for a coach that is asked about weight or calories.
    ///
    /// Every figure carries its provenance, and the corridor is handed over as a corridor rather than
    /// collapsed to one number. A coach told "you burn 2 480" will say it back with a confidence the
    /// underlying data does not support; one told three figures and their sources can say what is
    /// actually known — which is the difference between advice and a guess with a decimal point.
    func bodyAndEnergyBlock() async -> String {
        let metrics = await repo.bodyMetrics()
        let today = Repository.localDayKey(Date())
        var lines: [String] = []

        var body: [String] = []
        for key in ["weight", "body_fat", "waist"] {
            if let reading = metrics.asOf(key, day: today) {
                let age = reading.ageDays(on: today)
                body.append("\(key) \(reading.value.formatted(.number.precision(.fractionLength(1))))"
                            + " (\(reading.source), \(age)d ago)")
            }
        }
        lines.append(body.isEmpty
                     ? "Body: nothing recorded."
                     : "Body: " + body.joined(separator: "; "))

        let profile = Repository.analyticsProfile(ProfileStore())
        let summaries = await repo.energySummaries(days: 30, profile: profile)
        let days = summaries.filter { $0.day < today }.compactMap { summary -> BurnDay? in
            guard let total = summary.totalBurnedSoFar else { return nil }
            return BurnDay(day: summary.day, totalKcal: total, source: summary.source,
                           coverage: summary.coverage.energy)
        }
        let burn = EnergyPlanning.measuredBurn(days: days)
        if let measured = burn.measuredMeanKcal ?? burn.allDaysMeanKcal {
            lines.append("Measured burn: \(Int(measured.rounded())) kcal/day"
                         + " (\(burn.quality.rawValue), \(burn.measuredDays)/\(burn.totalDays) days measured)")
        }
        if let balance = await repo.adaptiveExpenditureEstimate() {
            lines.append("Energy balance: \(Int(balance.estimatedDailyKcal.rounded())) kcal/day"
                         + " (\(Int(balance.lowerBoundKcal.rounded()))–\(Int(balance.upperBoundKcal.rounded()))),"
                         + " from \(balance.intakeDays) intake days. Self-reported intake runs low, which biases this figure DOWN.")
        }
        let formula = EnergyPlanStore.formulaLog.current
        if let basal = BasalRate.kcalPerDay(formula,
                                            weightKg: metrics.value("weight", on: today) ?? profile.weightKg,
                                            heightCm: metrics.value("height", on: today) ?? profile.heightCm,
                                            age: profile.age, sex: profile.sex,
                                            bodyFatPercent: metrics.value("body_fat", on: today)) {
            lines.append("Basal rate: \(Int(basal.rounded())) kcal/day by \(formula.rawValue).")
        }
        lines.append("These are separate estimates, never averaged. Report the spread, not a single figure.")
        return "Body & energy:\n" + lines.joined(separator: "\n")
    }

    func strengthHistoryBlock(days: Int = 365, exercise: String? = nil, limit: Int = 6) async -> String {
        let window = max(1, min(days, 3_650))
        // One detailed set log per real session. The resolved history has already chosen between a
        // native log and an import of the same workout, so the coach cannot see one session twice.
        let history = await repo.resolvedStrengthHistory(days: window)
        let all = history.workouts.sorted { $0.startTs > $1.startTs }
        let needle = exercise?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessions = all.compactMap { workout -> HevyWorkout? in
            guard let needle, !needle.isEmpty else { return workout }
            let matches = workout.exercises.filter {
                $0.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .lowercased().contains(needle)
            }
            guard !matches.isEmpty else { return nil }
            return HevyWorkout(id: workout.id, title: workout.title, routineId: workout.routineId,
                               notes: workout.notes, startTs: workout.startTs, endTs: workout.endTs,
                               updatedAtTs: workout.updatedAtTs, createdAtTs: workout.createdAtTs,
                               exercises: matches, source: workout.source)
        }
        guard !sessions.isEmpty else { return "Strength history: no matching sessions in the last \(window) days." }

        var lines = ["STRENGTH HISTORY: \(sessions.count) sessions, \(dateString(sessions.last!.startTs)) → \(dateString(sessions.first!.startTs)), searched \(window) days."]
        let sourceCounts = Dictionary(grouping: sessions, by: \.source).mapValues(\.count)
        lines.append("Sources: " + sourceCounts.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.rawValue) \(sourceCounts[$0]!)" }.joined(separator: ", "))

        // ONE e1RM point per exercise per SESSION — its best working set — rather than one per set.
        // Feeding every set into the trend let a session with eight sets outvote one with two, so a
        // change in how someone trains moved a line that is supposed to be about how strong they are.
        struct LiftPoint { let ts: Int; let weight: Double; let reps: Int; let e1rm: Double }
        var points: [String: [LiftPoint]] = [:]
        var sessionBest: [String: [Int: LiftPoint]] = [:]
        for workout in sessions {
            for movement in workout.exercises {
                for set in movement.workingSets {
                    guard let weight = set.weightKg, weight > 0, let reps = set.reps, reps > 0 else { continue }
                    guard let e1rm = OneRepMax.epley(weightKg: weight, reps: reps) else { continue }
                    let point = LiftPoint(ts: workout.startTs, weight: weight, reps: reps, e1rm: e1rm)
                    points[movement.title, default: []].append(point)
                    let existing = sessionBest[movement.title]?[workout.startTs]
                    if existing == nil || e1rm > existing!.e1rm {
                        sessionBest[movement.title, default: [:]][workout.startTs] = point
                    }
                }
            }
        }
        lines.append("Exercise trends (e1RM is an estimate; top weight is measured; the trend is the median of every pairwise slope, so one bad session cannot flip it):")
        for name in points.keys.sorted().prefix(20) {
            let values = points[name]!.sorted { $0.ts < $1.ts }
            guard let first = values.first, let latest = values.last else { continue }
            let best = values.max { $0.e1rm < $1.e1rm }!
            let top = values.max { $0.weight < $1.weight }!
            var line = "  \(name): first e1RM \(String(format: "%.1f", first.e1rm)) kg, latest \(String(format: "%.1f", latest.e1rm)) kg, best \(String(format: "%.1f", best.e1rm)) kg; measured top \(String(format: "%.1f", top.weight)) kg × \(top.reps)."
            // The same robust line the Strength screen draws, so the coach and the chart can never
            // describe one history two different ways.
            let trendPoints = (sessionBest[name] ?? [:]).values
                .sorted { $0.ts < $1.ts }
                .map { point in
                    ExercisePerformancePoint(day: dateString(point.ts), startTs: point.ts,
                                             workoutId: "", bestE1RMKg: point.e1rm,
                                             heaviestSetKg: point.weight, workingSetCount: 1,
                                             totalReps: point.reps, volumeLoadKg: point.weight * Double(point.reps),
                                             meanRpe: nil, rpeSetCount: 0)
                }
            if let trend = StrengthProgress.e1rmTrend(trendPoints) {
                line += trend.directionIsUnclear
                    ? " Trend: no direction the sessions agree on (\(trend.pointCount) sessions)."
                    : " Trend: \(String(format: "%+.2f", trend.slopePerWeek)) kg/week over \(trend.spanDays) days."
            }
            lines.append(line)
        }

        // What the sessions were made of, per muscle and per axis. Without this the coach could name
        // every lift and still not answer "am I neglecting anything" — the question it is asked most.
        // The resolved history already merges native and imported templates, so one exercise carries one
        // name and one muscle mapping here. The type is spelled out to keep this body cheap to check.
        let templates: [String: HevyExerciseTemplate] = history.templates
        let windowStart = Int(Date().timeIntervalSince1970) - 28 * 86_400
        let fourWeeks = sessions.filter { $0.startTs >= windowStart }
        if !fourWeeks.isEmpty {
            let tally = StrengthSession.hardSetsByMuscle(fourWeeks, templates: templates)
            let byMuscle = tally.primary
                .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                .map { "\($0.key.label) \($0.value)" }
                .joined(separator: ", ")
            if !byMuscle.isEmpty {
                lines.append("Working sets per primary muscle, last 28 days: \(byMuscle)."
                    + (tally.unattributed > 0 ? " \(tally.unattributed) sets could not be attributed to a muscle." : ""))
            }
            let readings = StrengthBalance.readings(setsByMuscle: tally.primary).filter { $0.total > 0 }
            let balance = readings.compactMap { reading -> String? in
                guard let ratio = reading.ratio else { return nil }
                let labels = reading.axis.sideLabels
                return "\(labels.a):\(labels.b) \(String(format: "%.2f", ratio)):1"
            }.joined(separator: ", ")
            if !balance.isEmpty {
                lines.append("Balance over the same 28 days (counted sets, no target ratio exists): \(balance).")
            }
        }
        lines.append("Recent sessions:")
        for workout in sessions.prefix(max(1, min(limit, 12))) {
            let volume = workout.exercises.flatMap(\.workingSets).compactMap(\.volumeLoadKg).reduce(0, +)
            lines.append("  \(dateString(workout.startTs)) \(workout.title), id \(workout.id), \(String(format: "%.0f", volume)) kg volume [\(workout.source.rawValue)]")
            for movement in workout.exercises {
                let sets = movement.sets.map { set -> String in
                    var value = "\(set.weightKg.map { String(format: "%.1f kg", $0) } ?? "bodyweight") × \(set.reps.map(String.init) ?? "—")"
                    if set.type != .normal { value += " \(set.type.rawValue)" }
                    if let rpe = set.rpe { value += " RPE \(String(format: "%.1f", rpe))" }
                    return value
                }
                lines.append("    \(movement.title): \(sets.joined(separator: "; "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    /// `internal`, not private, so `AICoachSleepContextTests` can assert the emitted line directly.
    /// Swift's `buildContext()` takes no arguments (it reads the repo), unlike the Kotlin twin which is
    /// handed the day list — so without this the formatter has no seam and the Swift half of a change
    /// with fifteen Kotlin tests would ship untested.
    func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
        parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        // The stage breakdown and efficiency, which the coach could not see at all: a user asked why it
        // said it had no access to sleep stages, and it was answering honestly — `rest 7.8h` was every
        // word it got about a night. These four sit on the SAME DailyMetric the line already reads, so
        // nothing new is plumbed; they were simply never included. (#124 widened this context once
        // before, for the same reason.)
        //
        // Always emitted, "—" when absent, like every other field here. A night with no staging then
        // says so rather than going quiet, which matters more than line length: the alternative — only
        // appending stages when present — gives the model a schema that changes shape between days and
        // invites it to read a missing field as a zero.
        parts.append("deep " + hoursOrDash(d.deepMin))
        parts.append("REM " + hoursOrDash(d.remMin))
        parts.append("light " + hoursOrDash(d.lightMin))
        parts.append("eff " + efficiencyPercentOrDash(d.efficiency))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
    }

    /// Minutes as "1.4h", or "—" when the night has no value. Matches the `rest` field's format so a
    /// stage total and the total it is part of read on the same scale.
    private func hoursOrDash(_ minutes: Double?) -> String {
        minutes.map { String(format: "%.1fh", $0 / 60) } ?? "—"
    }

    /// Efficiency as a percentage, NORMALISING the stored value first.
    ///
    /// `DailyMetric.efficiency` is not reliably a 0–1 fraction: it "arrives as % on some import paths",
    /// which `SleepView` and `StagesCard` each guard against inline with this same `> 1.5` test. A bare
    /// `* 100` would therefore hand the coach "eff 9400%" for an imported night — and a model given a
    /// nonsense number reasons about it confidently rather than ignoring it.
    ///
    /// 1.5 rather than 1.0 because a genuine fraction can exceed 1.0 only by floating-point noise, while
    /// a genuine percentage is 30–100 and nowhere near the threshold. Android's two copies of this guard
    /// split at 1.0 instead, which is a pre-existing divergence and not this change's to settle.
    func efficiencyPercentOrDash(_ raw: Double?) -> String {
        guard var e = raw, e > 0 else { return "—" }
        if e > 1.5 { e /= 100 }
        guard e > 0, e <= 1 else { return "—" }
        return "\(Int((e * 100).rounded()))%"
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
