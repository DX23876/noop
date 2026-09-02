import Foundation

// MomentumFeed.swift — which single thing is worth saying right now, and in what order the rest follow.
//
// The Today card this drives used to be hard-wired to one sentence ("HRV n% over baseline" plus a
// recovery word). It had no type, so nothing could hang off it: no tone, no icon, no action, no
// progress. Meanwhile the app already computes goal progress, weekly session counts, streaks, planned
// workouts, step baselines and sleep need — none of which could ever reach the card.
//
// This is the pure half: a message MODEL and a RANKING. It deliberately carries no user-facing text of
// its own — `headline` / `detail` / `actionLine` arrive already localized from the app layer, the same
// posture `BaseCardStatement` takes. That keeps this package free of a string catalog and keeps every
// rule here testable with plain strings, no app, no strap, no database.
//
// The ordering is the part people will argue about, so it is written down rather than left implicit:
//   tier 0 urgent  →  1 time-critical goal  →  2 personal goals  →  3 training/recovery
//                  →  4 progress            →  5 positive insight
// with a TIME-OF-DAY nudge that reorders only WITHIN a tier (the recovery read leads the morning, the
// activity read the afternoon, sleep and the week's goals the evening).

// MARK: - Model

/// What a message is about. The tier — and therefore the whole ordering — is derived from this, so a
/// kind added later has to state where it belongs rather than silently landing at the end.
public enum MomentumKind: String, CaseIterable, Equatable, Sendable {
    /// The user has said they are sick / injured / on a break. An explicit statement outranks anything
    /// the app inferred.
    case statusOverride
    /// The baseline is still forming, so there is no score to read yet.
    case calibrating
    /// A workout was planned for today and none has been recorded.
    case planDeviation
    /// Sessions still owed this week, with the days left to do them in.
    case weeklyTrainingGoal
    /// The next waypoint on a long goal's route.
    case milestone
    /// The next body-weight waypoint.
    case weightMilestone
    /// Several straining days in a row — today should be a light one.
    case restDayNeeded
    /// Today's recovery read and what it means for training.
    case recoveryRead
    /// Recovery is high and the week's load is moderate: a good day to push.
    case trainingSuggestion
    /// Steps remaining to the day's goal.
    case stepGoal
    /// Today is quieter than this wearer's own normal.
    case stepsBelowUsual
    /// Sleep owed against the week's need.
    case sleepCatchUp
    /// Consecutive days meeting a goal.
    case streak
    /// A multi-day HRV direction against baseline.
    case hrvTrend

    /// Ordering tier, lower is more important. The comment above is the contract; this is it in code.
    public var tier: Int {
        switch self {
        case .statusOverride, .calibrating:        return 0
        case .planDeviation, .weeklyTrainingGoal:  return 1
        case .milestone, .weightMilestone:         return 2
        case .restDayNeeded, .recoveryRead, .trainingSuggestion: return 3
        case .stepGoal, .stepsBelowUsual, .sleepCatchUp:         return 4
        case .streak, .hrvTrend:                   return 5
        }
    }

    /// True when the message still makes sense on a NAVIGATED PAST DAY. "You still need 2,340 steps" is
    /// nonsense for last Tuesday; "recovery was good that day" is not. The card filters on this rather
    /// than hiding itself entirely, so a past day still reads as something.
    public var isRetrospective: Bool {
        switch self {
        case .recoveryRead, .hrvTrend, .streak, .milestone, .weightMilestone, .calibrating:
            return true
        case .statusOverride, .planDeviation, .weeklyTrainingGoal, .restDayNeeded,
             .trainingSuggestion, .stepGoal, .stepsBelowUsual, .sleepCatchUp:
            return false
        }
    }
}

/// How a message should feel — drives its colour and its symbol. Kept separate from the kind because
/// one kind spans several tones: a recovery read is `positive` at 91 and `critical` at 22.
public enum MomentumTone: String, CaseIterable, Equatable, Sendable {
    case positive, neutral, caution, critical
}

/// Where a message's action leads. Abstract on purpose: this package must not know about screens. The
/// set is exactly what the Today screen can actually open today — a destination it cannot honour would
/// be a button that does nothing.
public enum MomentumDestination: String, Equatable, Sendable {
    case none
    case chargeBreakdown
    case goalJourney
    case plan
    case liveSession
}

/// A tappable action under a message. `title` arrives already localized.
public struct MomentumAction: Equatable, Sendable {
    public let title: String
    public let destination: MomentumDestination
    public init(title: String, destination: MomentumDestination) {
        self.title = title
        self.destination = destination
    }
}

/// A progress read-out: the fraction, plus the two ways of saying it.
///
/// Both exist because the two surfaces need different ones. The Today card's detail line already spells
/// out the counts ("You're at 7,660 of 10,000 today"), so a chip repeating "7,660 / 10,000" beside it
/// said the same thing twice in one glance — the card shows `percentText` instead. The dashboard has
/// room for the exact figures and shows `label`.
public struct MomentumProgress: Equatable, Sendable {
    public let fraction: Double
    public let label: String
    public init(fraction: Double, label: String) {
        self.fraction = min(max(fraction, 0), 1)
        self.label = label
    }

    /// The fraction as a whole percent ("76 %"). Locale-independent formatting; the space before the
    /// sign matches the app's existing percentage read-outs.
    public var percentText: String { "\(Int((fraction * 100).rounded())) %" }
}

/// One thing worth saying. Every string is already localized by the builder.
public struct MomentumMessage: Equatable, Sendable {
    public let kind: MomentumKind
    public let tone: MomentumTone
    public let headline: String
    public let detail: String
    /// The "what to do about it" line. nil for a message that is purely a read.
    public let actionLine: String?
    public let progress: MomentumProgress?
    /// A short signed delta chip, e.g. "+5%".
    public let deltaText: String?
    public let action: MomentumAction?

    public init(kind: MomentumKind, tone: MomentumTone, headline: String, detail: String,
                actionLine: String? = nil, progress: MomentumProgress? = nil,
                deltaText: String? = nil, action: MomentumAction? = nil) {
        self.kind = kind
        self.tone = tone
        self.headline = headline
        self.detail = detail
        self.actionLine = actionLine
        self.progress = progress
        self.deltaText = deltaText
        self.action = action
    }
}

/// What the card showed last, and when. Passed IN rather than read from storage so `rank` stays pure;
/// the app holds it in `@AppStorage` so it survives a relaunch.
public struct MomentumLastShown: Equatable, Sendable {
    public let kind: MomentumKind
    public let at: Date
    public init(kind: MomentumKind, at: Date) {
        self.kind = kind
        self.at = at
    }
}

// MARK: - Ranking

public enum MomentumFeed {

    /// How long a message holds the card before a merely-better rival can take it. The card is
    /// re-evaluated on every body pass and every refresh, so without a dwell the headline could change
    /// while the user is reading it. Ninety minutes is long enough to be stable across a session and
    /// short enough that the morning read gives way by the afternoon.
    public static let minDwellSeconds: TimeInterval = 90 * 60

    /// How much better a challenger must score to take the card once the dwell has passed. Without a
    /// margin, two near-equal candidates trade places every time an input twitches.
    public static let switchMargin = 15

    /// One tier is worth this much.
    static let tierWeight = 100

    /// The strongest time-of-day nudge, deliberately a little MORE than one tier.
    ///
    /// It was first written as less than a tier, which quietly killed the whole feature: the recovery
    /// read sits a tier above the step read, so an afternoon step message could never take the card
    /// while a recovery read existed — and one essentially always exists. A nudge worth slightly more
    /// than one tier lets the message that genuinely belongs to this hour outrank the tier directly
    /// above it, while `maxBonus < 2 * tierWeight` guarantees it can never jump TWO — an urgent tier-0
    /// or a time-critical tier-1 message still leads at every hour of the day.
    ///
    /// The other half of keeping urgency honest is not here but in the BUILDER: a kind like
    /// `weeklyTrainingGoal` is time-critical only when the week is actually running out, so the builder
    /// emits it then and stays quiet otherwise. Urgency is "is there a candidate at all", not a
    /// permanently high tier that would block the rotation on every other day of the week.
    static let maxBonus = 120

    /// The time-of-day nudge for a kind, 0...`maxBonus`. Higher = more relevant at this hour.
    static func timeBonus(_ kind: MomentumKind, hour: Int) -> Int {
        let h = ((hour % 24) + 24) % 24
        switch h {
        case 4...11:   // morning — how did the night leave me, and what does that mean for today
            switch kind {
            case .recoveryRead, .restDayNeeded:  return maxBonus
            case .trainingSuggestion:            return 80
            case .hrvTrend:                      return 40
            default: return 0
            }
        case 12...17:  // afternoon — how is the day actually going
            switch kind {
            case .stepGoal, .stepsBelowUsual:    return maxBonus
            case .planDeviation:                 return 40
            default: return 0
            }
        case 18...23:  // evening — what is still owed, and how to land the day
            switch kind {
            case .sleepCatchUp:                  return maxBonus
            case .streak:                        return 80
            case .weeklyTrainingGoal:            return 40
            default: return 0
            }
        default:       // night — nothing to act on but sleep
            return kind == .sleepCatchUp ? maxBonus : 0
        }
    }

    /// How far a `critical` tone lifts a message. Just under one tier, so something that is actually
    /// wrong outranks its ordinary peers and the tier below it, but can never displace an explicit user
    /// statement (tier 0) and never reaches two tiers up.
    ///
    /// Tone had to enter the SCORE, not just the dwell rule. While it only broke the dwell, "you have
    /// had three straining days, make today a light one" lost the card to "2,340 steps to go" every
    /// afternoon — the step read is nudged hard at that hour and the rest-day read is not. A message
    /// that says something is wrong should not be ranked as if it were a progress note.
    static let criticalBonus = 90

    /// Ordering score for a message, LOWER is more important.
    static func score(_ message: MomentumMessage, hour: Int) -> Int {
        message.kind.tier * tierWeight
            - timeBonus(message.kind, hour: hour)
            - (message.tone == .critical ? criticalBonus : 0)
    }

    /// The candidates in the order the UI should use: the card takes `first`, the Momentum page shows
    /// the rest. Returns `[]` for an empty input rather than inventing a filler message — a card with
    /// nothing true to say should fall back to its previous behaviour, not make something up.
    ///
    /// `retrospective` (a navigated past day) drops every kind that only makes sense for today.
    ///
    /// The `lastShown` handling is what keeps the card from flickering. A challenger takes the card
    /// only if BOTH hold: the current message has had its dwell, and the challenger is better by more
    /// than `switchMargin`. The one exception is a `critical` message, which is allowed to interrupt —
    /// if something is actually wrong, a dwell timer is not a reason to keep quiet about it.
    public static func rank(_ candidates: [MomentumMessage],
                            hour: Int,
                            lastShown: MomentumLastShown? = nil,
                            now: Date = Date(),
                            retrospective: Bool = false) -> [MomentumMessage] {
        let pool = retrospective ? candidates.filter { $0.kind.isRetrospective } : candidates
        guard !pool.isEmpty else { return [] }

        // Stable sort: equal scores keep the builder's own order, so the output cannot shuffle between
        // two runs over identical inputs (the page's ordering depends on this too).
        let sorted = pool.enumerated()
            .sorted { a, b in
                let sa = score(a.element, hour: hour), sb = score(b.element, hour: hour)
                return sa == sb ? a.offset < b.offset : sa < sb
            }
            .map(\.element)

        guard let last = lastShown,
              let incumbentIndex = sorted.firstIndex(where: { $0.kind == last.kind }),
              incumbentIndex != 0,
              let leader = sorted.first
        else { return sorted }

        // A genuinely critical message is never held back by the incumbent's dwell.
        if leader.tone == .critical, sorted[incumbentIndex].tone != .critical { return sorted }

        let dwellElapsed = now.timeIntervalSince(last.at) >= minDwellSeconds
        let beatsByMargin = score(sorted[incumbentIndex], hour: hour) - score(leader, hour: hour) > switchMargin
        if dwellElapsed && beatsByMargin { return sorted }

        // Incumbent keeps the card; everything else holds its order behind it.
        var held = sorted
        let incumbent = held.remove(at: incumbentIndex)
        held.insert(incumbent, at: 0)
        return held
    }
}

// MARK: - Imagery

/// Which illustration a message carries, in the same shape as `DayCycleScene.assetName(hour:)`: a pure
/// name lookup, so the mapping is testable and the view stays dumb.
///
/// `nil` means "no artwork for this kind yet" and is the honest default — the card then renders its
/// tinted symbol tile, which is a complete design rather than a gap. Only the kinds whose meaning
/// genuinely matches the existing hand-painted day-cycle scenes are mapped; inventing a mapping for the
/// rest would put a sky behind a step count.
public enum MomentumScene {
    public static func assetName(for kind: MomentumKind) -> String? {
        switch kind {
        case .sleepCatchUp: return "scene4"   // night + moon
        case .recoveryRead: return "scene3"   // dawn
        default:            return nil
        }
    }
}
