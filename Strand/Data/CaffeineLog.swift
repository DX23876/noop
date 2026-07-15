import Foundation

// MARK: - Caffeine window (#526) — log an intake + a rough on-device "still active" estimate
//
// OPT-IN, MANUAL-FIRST: the user logs a caffeine intake (a time, and OPTIONALLY an amount in mg). NOOP
// then shows a plain "caffeine still active" hint on Today / Insights, computed entirely on-device from a
// simple exponential half-life decay. This is a ROUGH GUIDE from what the user logged, NOT a measurement
// and NOT a health claim — caffeine pharmacokinetics vary a lot between people (the ~5–6 h half-life is a
// population average). The honest framing lives in the copy; the math here just decays what was logged.
//
// Storage mirrors the native-journal pattern (UserDefaults-backed, single user). Nothing leaves the
// device. Default state is EMPTY (no intakes) — the feature surfaces nothing until the user logs one.

/// Pure caffeine half-life decay math. Headless — no I/O, no UI — so it's fully unit-tested.
///
/// Model: the fraction of a dose remaining after `t` hours is `0.5 ^ (t / halfLifeHours)` (first-order
/// elimination, the standard pharmacokinetic approximation). With multiple intakes the remaining amounts
/// simply add. The default half-life is 5.5 h — squarely in the commonly-cited ~5–6 h adult range — and
/// is exposed so the value is never a magic number.
public enum CaffeineDecay {

    /// The half-life used for the estimate, in hours. A population-average adult figure (~5–6 h); the
    /// estimate is only a rough guide because real clearance varies widely (genetics, smoking, pregnancy,
    /// medication). Surfaced via the copy, never as a precise per-user value.
    public static let defaultHalfLifeHours = 5.5

    /// Fraction (0...1) of a single dose still in the body `hoursElapsed` after intake. A negative elapsed
    /// time (a future-dated log) clamps to 1.0 (nothing has decayed yet) rather than amplifying the dose.
    public static func fractionRemaining(hoursElapsed: Double,
                                         halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        guard halfLifeHours > 0 else { return 0 }
        let t = max(0, hoursElapsed)
        return pow(0.5, t / halfLifeHours)
    }

    /// Estimated milligrams of caffeine still active from one dose of `mg`, `hoursElapsed` after intake.
    public static func remainingMg(doseMg: Double, hoursElapsed: Double,
                                   halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        max(0, doseMg) * fractionRemaining(hoursElapsed: hoursElapsed, halfLifeHours: halfLifeHours)
    }

    /// Total estimated mg still active across several intakes (each `(mg, hoursElapsed)`), at one moment.
    /// Intakes with an unknown dose are excluded from the mg total (we won't invent an amount) — the
    /// "still active" *flag* below covers the dose-unknown case instead.
    public static func totalRemainingMg(_ intakes: [(doseMg: Double, hoursElapsed: Double)],
                                        halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        intakes.reduce(0) { $0 + remainingMg(doseMg: $1.doseMg, hoursElapsed: $1.hoursElapsed,
                                             halfLifeHours: halfLifeHours) }
    }

    /// Hours until a single dose decays to `fraction` of itself (default 25% — a common "mostly cleared"
    /// rule of thumb). Two half-lives ≈ 25% remaining, so this is ~2 × halfLife at the default.
    public static func hoursUntilFraction(_ fraction: Double,
                                          halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        guard fraction > 0, fraction < 1, halfLifeHours > 0 else { return 0 }
        // 0.5 ^ (t / hl) = fraction  →  t = hl · log(fraction) / log(0.5)
        return halfLifeHours * (log(fraction) / log(0.5))
    }

    /// True when a dose is still meaningfully "active" `hoursElapsed` after intake — i.e. more than
    /// `threshold` (default 25%) of it remains. Used for the dose-UNKNOWN case (we can't show mg, but we
    /// can honestly say it's likely still active for a typical window).
    public static func isStillActive(hoursElapsed: Double,
                                     threshold: Double = 0.25,
                                     halfLifeHours: Double = defaultHalfLifeHours) -> Bool {
        fractionRemaining(hoursElapsed: hoursElapsed, halfLifeHours: halfLifeHours) > threshold
    }

    // MARK: - Cutoff window (PR#566, mvanhorn) — the latest caffeine time before bed.
    //
    // Reframes `hoursUntilFraction` as a clock-friendly "stop drinking after" cutoff: given a bedtime and
    // an acceptable residual fraction at bedtime, the cutoff is `bedtime − hoursUntilFraction(target)`. A
    // dose at the cutoff decays to exactly `targetResidualFraction` by bedtime; anything later still has
    // more than that on board. Same decay model as the "still active" hint — only the framing changes.

    /// Default acceptable residual at bedtime: a quarter of the dose (two half-lives), matching the
    /// `isStillActive` threshold so "still active" and "past cutoff" agree.
    public static let defaultBedtimeResidual = 0.25

    /// Hours BEFORE bedtime the cutoff falls — the lead time over which a dose decays to
    /// `targetResidualFraction`. A pure number (no clock); the UI subtracts it from bedtime.
    public static func cutoffLeadHours(targetResidualFraction: Double = defaultBedtimeResidual,
                                       halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        hoursUntilFraction(targetResidualFraction, halfLifeHours: halfLifeHours)
    }

    /// The caffeine cutoff as minutes-since-midnight, given a `bedtimeMinutes` (also since midnight),
    /// normalised into [0, 1440) so an early bedtime + long lead doesn't read as a negative time. Pure.
    public static func cutoffMinutesSinceMidnight(bedtimeMinutes: Int,
                                                  targetResidualFraction: Double = defaultBedtimeResidual,
                                                  halfLifeHours: Double = defaultHalfLifeHours) -> Int {
        let leadMin = Int(cutoffLeadHours(targetResidualFraction: targetResidualFraction,
                                          halfLifeHours: halfLifeHours) * 60)
        let raw = bedtimeMinutes - leadMin
        return ((raw % 1440) + 1440) % 1440
    }

    /// True when an intake at `intakeMinutes` (minutes since midnight) is later than the cutoff for
    /// `bedtimeMinutes` — i.e. it'll still have more than `targetResidualFraction` on board at bedtime.
    public static func isPastCutoff(intakeMinutes: Int,
                                    bedtimeMinutes: Int,
                                    targetResidualFraction: Double = defaultBedtimeResidual,
                                    halfLifeHours: Double = defaultHalfLifeHours) -> Bool {
        let leadMin = Int(cutoffLeadHours(targetResidualFraction: targetResidualFraction,
                                          halfLifeHours: halfLifeHours) * 60)
        // Compare on the raw (un-normalised) axis so a cutoff in the previous evening makes every
        // positive same-day intake "past cutoff".
        return intakeMinutes > (bedtimeMinutes - leadMin)
    }
}

/// One logged caffeine intake — a timestamp and an OPTIONAL amount in mg. Codable for UserDefaults JSON.
public struct CaffeineIntake: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// When the caffeine was consumed (the user's logged time).
    public let at: Date
    /// Amount in mg, if the user gave one. nil = "logged it, didn't say how much" — we never invent a number.
    public let mg: Double?

    public init(id: UUID = UUID(), at: Date, mg: Double? = nil) {
        self.id = id; self.at = at; self.mg = mg
    }
}

/// A computed, honest summary of the caffeine still active right now from the logged intakes.
public struct CaffeineActiveEstimate: Equatable, Sendable {
    /// Intakes that are still meaningfully active (> the active threshold).
    public let activeIntakeCount: Int
    /// Total estimated mg still active, summed across intakes that HAD a known dose. nil when no active
    /// intake carried an amount (so the UI shows the dose-unknown phrasing rather than a fabricated mg).
    public let totalRemainingMg: Double?
    /// Hours since the MOST RECENT still-active intake — for the "had one ~Nh ago" phrasing.
    public let hoursSinceMostRecentActive: Double?

    /// True when at least one logged intake is still estimated to be active.
    public var hasActive: Bool { activeIntakeCount > 0 }

    public init(activeIntakeCount: Int, totalRemainingMg: Double?, hoursSinceMostRecentActive: Double?) {
        self.activeIntakeCount = activeIntakeCount
        self.totalRemainingMg = totalRemainingMg
        self.hoursSinceMostRecentActive = hoursSinceMostRecentActive
    }

    /// Build the estimate for `now` from a set of intakes, using the decay model. Pure → unit-tested.
    public static func compute(intakes: [CaffeineIntake], now: Date = Date(),
                               halfLifeHours: Double = CaffeineDecay.defaultHalfLifeHours,
                               activeThreshold: Double = 0.25) -> CaffeineActiveEstimate {
        var activeCount = 0
        var mgSum = 0.0
        var anyMg = false
        var mostRecentActiveHours: Double?

        for intake in intakes {
            let hours = now.timeIntervalSince(intake.at) / 3600.0
            // A future-dated intake (hours < 0) isn't "active yet" — don't count it.
            guard hours >= 0,
                  CaffeineDecay.isStillActive(hoursElapsed: hours, threshold: activeThreshold,
                                              halfLifeHours: halfLifeHours) else { continue }
            activeCount += 1
            if let mg = intake.mg {
                mgSum += CaffeineDecay.remainingMg(doseMg: mg, hoursElapsed: hours, halfLifeHours: halfLifeHours)
                anyMg = true
            }
            if mostRecentActiveHours == nil || hours < mostRecentActiveHours! {
                mostRecentActiveHours = hours
            }
        }
        return CaffeineActiveEstimate(activeIntakeCount: activeCount,
                                      totalRemainingMg: anyMg ? mgSum : nil,
                                      hoursSinceMostRecentActive: mostRecentActiveHours)
    }
}

/// UserDefaults-backed store of the user's logged caffeine intakes. Single user, on-device only, default
/// empty. Mirrors the `JournalCatalogStore` persistence style (a `@Published` array with a `didSet` save).
/// Old intakes are pruned on load so the blob stays small — anything past the "fully cleared" horizon is
/// irrelevant to the estimate and to any same-day review.
@MainActor
public final class CaffeineLogStore: ObservableObject {

    /// One shared instance (NOOP AI): the coach's `log_caffeine` tool and the Caffeine card write and
    /// observe the SAME store, so a chat-logged intake appears in the card immediately — and two
    /// instances can never clobber each other's UserDefaults blob.
    public static let shared = CaffeineLogStore()

    /// Logged intakes, newest first. Persisted as JSON under one UserDefaults key.
    @Published public private(set) var intakes: [CaffeineIntake] { didSet { save() } }

    private let d: UserDefaults
    private let now: () -> Date
    private static let key = "caffeine.intakes"
    /// Drop intakes older than this many hours on load — well past the decay horizon, so the estimate is
    /// unchanged but the stored array can't grow without bound.
    static let retentionHours = 48.0

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.d = defaults
        self.now = now
        let loaded = (try? JSONDecoder().decode([CaffeineIntake].self,
                                                from: d.data(forKey: Self.key) ?? Data())) ?? []
        let cutoff = now().addingTimeInterval(-Self.retentionHours * 3600)
        self.intakes = loaded
            .filter { $0.at >= cutoff }
            .sorted { $0.at > $1.at }
    }

    /// Log a new intake. `mg` is optional — pass nil when the user only logged "I had caffeine".
    public func log(at date: Date, mg: Double? = nil) {
        // Guard a non-finite / negative mg so a fat-fingered field can't poison the estimate; nil it out
        // rather than store garbage (honest: unknown amount > wrong amount).
        let cleanMg: Double? = {
            guard let mg, mg.isFinite, mg > 0 else { return nil }
            return min(mg, 2000)   // a sane upper clamp (no single drink is ~2000 mg)
        }()
        intakes = ([CaffeineIntake(at: date, mg: cleanMg)] + intakes).sorted { $0.at > $1.at }
    }

    /// Remove a logged intake (the user mis-logged / wants to clear it).
    public func remove(_ id: UUID) {
        intakes = intakes.filter { $0.id != id }
    }

    /// Clear every logged intake.
    public func clearAll() {
        intakes = []
    }

    /// The current "still active" estimate, computed from the logged intakes at `now()`.
    public func estimate(halfLifeHours: Double = CaffeineDecay.defaultHalfLifeHours)
        -> CaffeineActiveEstimate {
        CaffeineActiveEstimate.compute(intakes: intakes, now: now(), halfLifeHours: halfLifeHours)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(intakes) { d.set(data, forKey: Self.key) }
    }
}
