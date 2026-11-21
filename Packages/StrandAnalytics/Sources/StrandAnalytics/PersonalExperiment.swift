import Foundation

/// The Personal Experiment card's arithmetic: one behaviour the wearer deliberately tests against one
/// outcome, as a baseline-versus-intervention contrast.
///
/// Pure and shared so the figure cannot be derived twice. It used to live privately in each Insights
/// screen, and both copies padded the baseline with days the wearer never answered — so a behaviour
/// logged on only a few days was compared against weeks of silence, and the same behaviour read one way
/// here and another way in Behaviour Effects on the same screen. `EffectRanker` had already been given an
/// EXPLICIT control set for exactly that reason ("if I didn't track something for 100 days, NOOP takes
/// that as a NO for 100 days"); this is the same rule, applied to the experiment card. (Refs #2923)
public enum PersonalExperiment {
    /// What the card states, for a caller that adds the wording and the confidence label.
    public struct Snapshot: Equatable, Sendable {
        /// The baseline days taken, oldest first: explicit NO days before the start, latest ones first
        /// taken, never a day with no answer.
        public let baselineDays: [String]
        /// The logged (YES) days inside the experiment window, oldest first.
        public let interventionDays: [String]
        public let baselineMean: Double?
        public let interventionMean: Double?
        /// Days since the start, counted inclusively and capped at the chosen duration.
        public let daysElapsed: Int
        /// Logged days over days elapsed, in percent.
        public let compliancePct: Double

        public init(baselineDays: [String], interventionDays: [String],
                    baselineMean: Double?, interventionMean: Double?,
                    daysElapsed: Int, compliancePct: Double) {
            self.baselineDays = baselineDays
            self.interventionDays = interventionDays
            self.baselineMean = baselineMean
            self.interventionMean = interventionMean
            self.daysElapsed = daysElapsed
            self.compliancePct = compliancePct
        }

        public var baselineCount: Int { baselineMean == nil ? 0 : baselineDays.count }
        public var interventionCount: Int { interventionMean == nil ? 0 : interventionDays.count }
        /// The pairing the confidence label reads: the smaller of the two sides.
        public var pairedCount: Int { min(baselineCount, interventionCount) }
        public var delta: Double? {
            guard let interventionMean, let baselineMean else { return nil }
            return interventionMean - baselineMean
        }
    }

    /// The snapshot for one experiment, or nil when it has not started.
    ///
    /// - Parameters:
    ///   - outcomeByDay: the outcome's value per day key, the only days that can enter either side.
    ///   - loggedDays: the days the behaviour was answered YES.
    ///   - controlDays: the days it was answered NO. A day in neither set is unanswered and enters
    ///     NEITHER side: it is not evidence that the behaviour was absent.
    ///   - baselineWindowDays: how many baseline days to take, the most recent ones before the start.
    public static func snapshot(outcomeByDay: [String: Double],
                                loggedDays: Set<String>,
                                controlDays: Set<String>,
                                startedDay: String,
                                today: String,
                                durationDays: Int,
                                baselineWindowDays: Int) -> Snapshot? {
        guard !startedDay.isEmpty else { return nil }
        let duration = max(1, durationDays)
        let baselineDays = outcomeByDay.keys
            .filter { $0 < startedDay && controlDays.contains($0) && !loggedDays.contains($0) }
            .sorted()
            .suffix(max(1, baselineWindowDays))
        let interventionDays = outcomeByDay.keys
            .filter { $0 >= startedDay && $0 <= today }
            .sorted()
            .prefix(duration)
            .filter { loggedDays.contains($0) }
        let baselineValues = baselineDays.compactMap { outcomeByDay[$0] }
        let interventionValues = interventionDays.compactMap { outcomeByDay[$0] }
        let elapsed = min(duration, max(1, TrainingHistory.daysBetween(startedDay, today) + 1))
        return Snapshot(baselineDays: Array(baselineDays),
                        interventionDays: Array(interventionDays),
                        baselineMean: mean(baselineValues),
                        interventionMean: mean(interventionValues),
                        daysElapsed: elapsed,
                        compliancePct: Double(interventionDays.count) / Double(max(elapsed, 1)) * 100)
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
