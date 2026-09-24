import Foundation

// MARK: - Which VO₂max is shown, and what counts as cardio performance evidence
//
// Two separate questions, deliberately answered separately.
//
// WHICH NUMBER TO SHOW. NOOP's weekly estimate (`vo2max_est`) is always current while the band is worn,
// and one source draws one unbroken line. Apple Watch's Cardio Fitness is measured during outdoor
// effort and is the better measurement — but only while the watch is worn: a reading from five weeks
// ago shown as today's value tells the wearer something that is no longer true. So the estimate is the
// headline everywhere, and the latest Apple reading is shown beside it WITH its date.
//
// WHAT COUNTS AS EVIDENCE that cardio training is working. NOT NOOP's estimate: Nes 2011 is built from a
// physical-activity index that NOOP derives from Effort, so more training raises the estimate by
// construction (three days at Effort 45 → five days at Effort 75 is +2.0 ml/kg/min at an unchanged
// resting HR, past the 1.5 floor), and Uth 2004 is resting heart rate alone, which the recovery reading
// already uses. Evidence has to be performance, as the lifts' e1RM is for strength:
//
//   1. Apple's measured VO₂max, while it is fresh — at least four readings in eight weeks AND the latest
//      no more than fourteen days old;
//   2. otherwise heart-rate efficiency: beats per kilometre in the wearer's main endurance sport, the
//      same Theil–Sen line and agreement rule as a lift, and a change of at least 3 % across the window
//      (NOOP's own floor — beats per kilometre moves with heat, hills and pace, and a smaller drift
//      describes the conditions rather than the athlete);
//   3. otherwise no evidence, and the verdict only describes the load.

/// The VO₂max number every surface shows, and the Apple reading kept beside it.
public struct VO2maxDisplay: Equatable, Sendable {
    /// The headline value: the latest NOOP estimate, or the latest Apple reading when there is none.
    public let primary: VO2maxReading?
    /// The headline source's line over the last eight weeks, one estimator segment only — for a chart,
    /// never for a verdict.
    public let line: VO2maxResponse
    /// The latest Apple Watch reading, shown with its date beside a NOOP headline. Nil when the headline
    /// is itself Apple's, or Apple has none.
    public let appleLatest: VO2maxReading?

    public init(primary: VO2maxReading?, line: VO2maxResponse, appleLatest: VO2maxReading?) {
        self.primary = primary
        self.line = line
        self.appleLatest = appleLatest
    }
}

/// Heart-rate efficiency in one sport over the evidence window.
public struct HeartRateEfficiencyReading: Equatable, Sendable {
    /// The stored sport label the line was drawn through; sessions of other labels are not mixed in.
    public let sport: String
    /// `.improving` when fewer beats cover a kilometre.
    public let direction: FitnessDirection
    public let sessions: Int
    /// The change the line implies across its span, as a percentage of the typical value. Negative is
    /// fewer beats per kilometre. Nil without a line.
    public let changePercent: Double?
    public let spanDays: Int

    public init(sport: String, direction: FitnessDirection, sessions: Int, changePercent: Double?, spanDays: Int) {
        self.sport = sport
        self.direction = direction
        self.sessions = sessions
        self.changePercent = changePercent
        self.spanDays = spanDays
    }
}

/// Where the cardio lane's performance evidence came from.
public enum CardioEvidenceSource: String, Equatable, Sendable, Codable {
    case appleVO2max
    case heartRateEfficiency
    case none
}

/// The cardio lane's performance evidence and what it rests on.
public struct CardioEvidenceReading: Equatable, Sendable {
    public let evidence: LaneEvidence
    public let source: CardioEvidenceSource
    /// Apple's line, when fresh Apple readings decided the evidence.
    public let apple: VO2maxResponse?
    /// The efficiency line, whenever one could be read — also when fresh Apple readings took precedence.
    public let efficiency: HeartRateEfficiencyReading?

    public init(evidence: LaneEvidence, source: CardioEvidenceSource, apple: VO2maxResponse?,
                efficiency: HeartRateEfficiencyReading?) {
        self.evidence = evidence
        self.source = source
        self.apple = apple
        self.efficiency = efficiency
    }

    /// How many readings or sessions the evidence rests on.
    public var observations: Int {
        switch source {
        case .appleVO2max: return apple?.readings.count ?? 0
        case .heartRateEfficiency: return efficiency?.sessions ?? 0
        case .none: return 0
        }
    }
}

public enum CardioEvidence {

    /// The oldest the latest Apple reading may be for Apple to count as current.
    public static let appleFreshnessDays = 14
    /// The smallest change in beats per kilometre, relative to its typical value, that counts as a
    /// direction. NOOP's own floor.
    public static let efficiencyMinimumChange = 0.03

    // MARK: - Display

    /// The headline VO₂max and the Apple reading beside it.
    public static func display(estimates: [VO2maxReading], apple: [VO2maxReading],
                               through day: String) -> VO2maxDisplay {
        let known = estimates.filter { $0.day <= day && $0.value > 0 }
        let appleKnown = apple.filter { $0.day <= day && $0.value > 0 }.sorted { $0.day < $1.day }
        if let latest = known.max(by: { $0.day < $1.day }) {
            return VO2maxDisplay(primary: latest,
                                 line: TrainingStatusModel.vo2maxResponse(readings: known, through: day),
                                 appleLatest: appleKnown.last)
        }
        return VO2maxDisplay(primary: appleKnown.last,
                             line: TrainingStatusModel.vo2maxResponse(readings: appleKnown, through: day),
                             appleLatest: nil)
    }

    /// Whether Apple's readings are current enough to be the evidence.
    public static func appleIsFresh(_ apple: [VO2maxReading], through day: String) -> Bool {
        let windowStart = WeeklyDigestEngine.addDays(day, -(TrainingStatusModel.vo2maxWindowDays - 1))
        let inWindow = apple.filter { $0.day >= windowStart && $0.day <= day && $0.value > 0 }
        guard inWindow.count >= StrengthProgress.minimumTrendPoints,
              let latest = inWindow.map(\.day).max() else { return false }
        return StrengthSession.daysBetween(latest, and: day) <= appleFreshnessDays
    }

    // MARK: - Evidence

    /// The cardio lane's evidence, in order of strength: fresh Apple VO₂max, heart-rate efficiency, none.
    public static func reading(apple: [VO2maxReading], sessions: [CardioSessionMetrics],
                               through day: String) -> CardioEvidenceReading {
        let efficiency = heartRateEfficiency(sessions, through: day)
        if appleIsFresh(apple, through: day) {
            let response = TrainingStatusModel.vo2maxResponse(readings: apple, through: day)
            if response.direction != .unknown {
                return CardioEvidenceReading(evidence: LaneEvidence(response.direction), source: .appleVO2max,
                                             apple: response, efficiency: efficiency)
            }
        }
        if let efficiency, efficiency.direction != .unknown {
            return CardioEvidenceReading(evidence: LaneEvidence(efficiency.direction), source: .heartRateEfficiency,
                                         apple: nil, efficiency: efficiency)
        }
        return CardioEvidenceReading(evidence: .none, source: .none, apple: nil, efficiency: efficiency)
    }

    /// Beats per kilometre in the main endurance sport over the last eight weeks.
    ///
    /// The main sport is the endurance label with the most sessions carrying a beats-per-kilometre figure
    /// (ties go to the alphabetically first label, so the choice never depends on read order). Only that
    /// exact label is read: "Running" and "Treadmill run" are both on foot and do not cost the same beats.
    /// Nil when no endurance session in the window carries the figure.
    public static func heartRateEfficiency(_ sessions: [CardioSessionMetrics],
                                           through day: String) -> HeartRateEfficiencyReading? {
        let windowStart = WeeklyDigestEngine.addDays(day, -(TrainingStatusModel.vo2maxWindowDays - 1))
        let endurance: Set<CardioModality> = [.foot, .cycling, .swimming, .rowing]
        let eligible = sessions.filter {
            $0.day >= windowStart && $0.day <= day && endurance.contains($0.modality) && $0.beatsPerKm != nil
        }
        var bySport: [String: [CardioSessionMetrics]] = [:]
        for session in eligible { bySport[session.sport.lowercased(), default: []].append(session) }
        guard let main = bySport.max(by: { lhs, rhs in
            lhs.value.count != rhs.value.count ? lhs.value.count < rhs.value.count : lhs.key > rhs.key
        }) else { return nil }

        let sport = main.value.first?.sport ?? main.key
        let points = main.value.compactMap { session -> ExercisePerformancePoint? in
            guard let beats = session.beatsPerKm else { return nil }
            return ExercisePerformancePoint(day: session.day, startTs: session.startTs, workoutId: "",
                                            bestE1RMKg: beats, heaviestSetKg: nil, workingSetCount: 0,
                                            totalReps: 0, volumeLoadKg: 0, meanRpe: nil, rpeSetCount: 0)
        }
        guard let line = StrengthProgress.e1rmTrend(points) else {
            return HeartRateEfficiencyReading(sport: sport, direction: .unknown, sessions: points.count,
                                              changePercent: nil, spanDays: 0)
        }
        let values = points.compactMap(\.bestE1RMKg).sorted()
        let typical = values[values.count / 2]
        let change = typical > 0 ? line.changeOverSpan / typical : 0
        let direction: FitnessDirection
        if line.directionIsUnclear || abs(change) < efficiencyMinimumChange {
            direction = .unclear
        } else {
            direction = line.slopePerWeek < 0 ? .improving : .worsening
        }
        return HeartRateEfficiencyReading(sport: sport, direction: direction, sessions: line.pointCount,
                                          changePercent: change * 100, spanDays: line.spanDays)
    }
}
