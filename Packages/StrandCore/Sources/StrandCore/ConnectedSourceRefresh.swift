import Foundation

/// "Fetch now, from everything that feeds this app": the rules behind the pull gesture, shared so both
/// phones answer a pull the same way.
///
/// The asking itself cannot be shared — Health Connect exists only on Android, HealthKit only on Apple,
/// and the strap is each platform's own Bluetooth stack. What IS shared, and what used to drift, is
/// everything around it: which sources may be asked, how often a wearer may ask, and how several answers
/// become ONE sentence. The shell reports "this source is connected" and "this is what it brought"; the
/// decisions live here.
///
/// Deliberately not here: the wording. A platform renders the verdict from its own catalogue, so the
/// sentence is translated once per platform rather than carried through the bridge. The source guard in
/// `Tools/` is what keeps the two catalogues saying the same thing.
public enum ConnectedSourceRefresh {

    /// What a pull can ask. One slot for "the platform's health store", because a wearer has Health
    /// Connect or HealthKit, never both, and the sentence must not name the plumbing.
    public enum Source: String, CaseIterable, Sendable, Codable {
        case health
        case hevy
        case strap
    }

    /// What one source answered.
    ///
    /// `brought` counts what actually arrived, so a source that ran and found nothing is not the same as
    /// one that never ran. It is OPTIONAL because not every importer counts: Apple's HealthKit sync
    /// answers with success or failure and nothing else. A source that ran without a count must not be
    /// read as "brought nothing", or the line would say everything is current in the same breath as
    /// three workouts arriving.
    public struct Answer: Equatable, Sendable {
        public let source: Source
        public let brought: Int?
        public let failed: Bool

        public init(source: Source, brought: Int? = 0, failed: Bool = false) {
            self.source = source
            self.brought = brought
            self.failed = failed
        }
    }

    /// What the screen should say, as structure rather than text.
    public enum Verdict: Equatable, Sendable {
        /// Everything that ran had nothing new, and nothing failed.
        case upToDate
        /// Something arrived; the number is across all sources that brought anything.
        case brought(total: Int)
        /// Something ran and brought no count of its own, so there is nothing to put a number on. Said
        /// rather than "up to date", which would be a claim this answer cannot support.
        case refreshed
        /// Only the strap was asked. It carries its own progress and can run for minutes, so this makes
        /// no claim about freshness — but silence is not the answer either: the wearer pulled, something
        /// began, and a screen that says nothing reads as a gesture that did nothing (owner's iPhone,
        /// 2026-11-22).
        case strapAsked
        /// At least one source could not be reached. `brought` may still be non-zero: naming only the
        /// failure would throw away what did arrive, which is the kind of half-true line this project
        /// keeps removing.
        case partial(failed: [Source], brought: Int)
    }

    /// How soon a wearer may ask the same source again. A gesture can be repeated every second; a source
    /// behind someone else's web API cannot. The in-flight guard only stops overlap — this stops a
    /// drumbeat of back-to-back runs that each finish.
    public static let floorSeconds: Int = 30

    /// The connected sources that may be asked right now. Unix seconds throughout; a source missing from
    /// `lastAsked` has never been asked and is always askable.
    public static func askable(connected: Set<Source>,
                               lastAsked: [Source: Int],
                               now: Int,
                               floor: Int = floorSeconds) -> Set<Source> {
        connected.filter { source in
            guard let last = lastAsked[source] else { return true }
            // A clock that went backwards (a manual change, a DST jump on a wall-clock source) must not
            // lock the gesture out until it catches up: anything in the future counts as "long ago".
            if last > now { return true }
            return now - last >= floor
        }
    }

    /// One verdict from the answers, or nil when there is nothing to say.
    ///
    /// The strap never decides it. A strap sync can run for minutes and has its own progress on screen,
    /// so the gesture treats it as "asked" and the line speaks for the services that finish in a breath.
    /// A pull that asked nothing but the strap therefore says nothing at all, rather than claiming
    /// everything is current while an offload is still running.
    public static func verdict(_ answers: [Answer]) -> Verdict? {
        let services = answers.filter { $0.source != .strap }
        guard !services.isEmpty else {
            return answers.contains { $0.source == .strap } ? .strapAsked : nil
        }
        let failed = services.filter(\.failed).map(\.source)
        let ran = services.filter { !$0.failed }
        let brought = ran.reduce(0) { $0 + ($1.brought ?? 0) }
        if !failed.isEmpty { return .partial(failed: failed, brought: brought) }
        if brought > 0 { return .brought(total: brought) }
        // Ran, nothing counted, and at least one source cannot count: say so rather than promise.
        return ran.contains { $0.brought == nil } ? .refreshed : .upToDate
    }
}
