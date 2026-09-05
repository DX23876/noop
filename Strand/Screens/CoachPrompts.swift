import Foundation

/// The suggested questions offered when a Coach thread is empty (#1862).
///
/// Extracted from `CoachView` so the Today launcher sheet and the full screen offer the SAME prompts.
/// Two hardcoded lists would have drifted the moment either was edited, and the launcher's whole
/// purpose is to be a shortcut into the screen rather than a second, subtly different Coach.
///
/// ## Why these are now chosen rather than fixed
///
/// A static list is wrong most of the time in a specific way: it offers "Analyse my sleep" to someone
/// who has not worn the strap, and "What should today's training look like?" at ten at night. The
/// question a person actually wants is usually about the thing that just happened — they trained, they
/// woke up flat, a draft is waiting for them.
///
/// The selection is a PURE function of facts the screen already has. No model call, no extra query,
/// nothing derived here: a suggestion chip is a shortcut, and one that cost a request or a computation
/// would be a worse deal than typing the question. The fixed list below is the fallback, and on a fresh
/// install with nothing synced it is still exactly what is shown.
enum CoachPrompts {

    /// What the screen already knows when it draws the chips. Every field is optional or a plain flag,
    /// because this must never force a caller to compute something to ask the question.
    struct Context: Equatable {
        /// Today's Charge, when there is one.
        var chargeToday: Double?
        /// The user's own recent Charge average, for "is today unusual FOR ME" rather than a fixed
        /// threshold — the same principle every other comparison in the app follows.
        var chargeBaseline: Double?
        /// A workout was logged today.
        var trainedToday = false
        /// A strength session specifically — a different question follows one of those.
        var strengthToday = false
        /// Hevy is connected, so strength questions can actually be answered.
        var hevyConnected = false
        /// A coach draft (goal or routine) is waiting for a decision.
        var hasPendingDraft = false
        /// Last night produced a sleep figure.
        var hasSleepLastNight = false

        public init() {}
    }

    /// The fallback, and the list a brand-new install sees. Unchanged strings with their existing
    /// String Catalog keys, so nothing needs retranslating.
    static let suggestions: [String] = [
        String(localized: "How's my charge trending?"),
        String(localized: "What should today's training look like?"),
        String(localized: "Analyse my sleep"),
        String(localized: "Why am I run down?"),
    ]

    /// How many chips to offer. Four is the point where a row of shortcuts stops being a shortcut and
    /// becomes a menu to read.
    static let maxSuggestions = 4

    /// Pick the prompts worth offering right now, most relevant first.
    ///
    /// Deterministic and total: the same context always produces the same list, and the fallback fills
    /// any remainder so the row is never short. Ordering is by how recently the thing happened — what
    /// just occurred beats a standing question about a trend.
    static func suggestions(for context: Context) -> [String] {
        var out: [String] = []

        // A session just finished. This is the moment someone actually opens the coach.
        if context.strengthToday && context.hevyConnected {
            out.append(String(localized: "How was my training today?"))
        } else if context.trainedToday {
            out.append(String(localized: "How was my training today?"))
        }

        // Charge below the user's OWN average, not below a fixed number. A person who lives at 45 does
        // not need to be asked why they are run down every single morning.
        if let charge = context.chargeToday, let baseline = context.chargeBaseline,
           charge < baseline - 8 {
            out.append(String(localized: "Why is my charge low today?"))
        }

        // A decision is waiting. Surfacing it as a question is gentler than a badge and gets the same
        // thing looked at.
        if context.hasPendingDraft {
            out.append(String(localized: "Talk me through the draft you prepared"))
        }

        if context.hevyConnected {
            out.append(String(localized: "Show me my strength progress"))
            if !context.strengthToday {
                out.append(String(localized: "What should I train today?"))
            }
        }

        if context.hasSleepLastNight {
            out.append(String(localized: "Analyse my sleep"))
        }

        // Top up from the standing list, skipping anything already offered, so the row is always full
        // and a sparse context still gets four sensible questions.
        for fallback in suggestions where !out.contains(fallback) {
            if out.count >= maxSuggestions { break }
            out.append(fallback)
        }
        return Array(out.prefix(maxSuggestions))
    }
}
