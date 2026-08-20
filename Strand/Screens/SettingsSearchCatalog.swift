import Foundation

/// Stable identity for each `SettingsSection` card on the Settings screen.
///
/// Exists so a section can be *addressed* — filtered by the Settings search field, and named as a
/// result row in the More tab's index search — without matching on its display title, which is
/// translated and therefore not a key.
enum SettingsSectionID: String, CaseIterable, Hashable, Sendable {
    case profile
    case units
    case streak
    case appearance
    case strap
    case recovery
    /// HRV tuning, moved out of the always-visible Strap card into Advanced (upstream #518).
    case hrv
    case testCentre
    case features
    case liveSessions
    case sleepStaging
    case experimentalWhoop5
    case diagnostics
    case backup
    case about
}

/// What the search field knows about a Settings section: the name to show as a result row, and the
/// words a person might actually type looking for something inside it.
struct SettingsSearchEntry: Identifiable, Sendable {
    let id: SettingsSectionID
    /// Result-row label. Deliberately its own string rather than a read-back of the section header:
    /// a `LocalizedStringKey` at the call site cannot be resolved to text, and a result row wants a
    /// self-contained name anyway ("Experimental · WHOOP 5 / MG" reads fine mid-list).
    let title: LocalizedStringResource
    /// The controls inside the section, in the words a person would search for. These are what make
    /// "live activity", "dark mode" or "battery" land on the right card — the section titles alone
    /// never would.
    ///
    /// Plain `String`, i.e. English-only, while `title` above is translated: a non-English reader
    /// still finds every section by its own name, and the keywords add reach on top. Localizing them
    /// would push ~120 synonym keys through the string catalog, many of which ("ECG", "CSV",
    /// "HealthKit", "noopbak") are word-for-word identical in every language — exactly what
    /// `Tools/i18n_audit.py`'s echo gate rejects. It also made matching depend on the running
    /// language: `MoreCatalogTests` caught a German-locale run where "API key" resolved to its German
    /// translation and the query "api key" then matched nothing.
    let keywords: [String]
}

/// The searchable index of the Settings screen.
///
/// Hand-written on purpose: the alternative is reading control labels back out of the view tree,
/// which SwiftUI does not offer and which would tie the index to layout. `SettingsSearchCatalogTests`
/// pins the one invariant that matters — every `SettingsSectionID` has exactly one entry — so a
/// section added later cannot silently become unfindable.
enum SettingsSearchCatalog {

    static let entries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: .profile,
            title: "Profile",
            keywords: ["photo", "picture", "avatar", "name", "date of birth", "age",
                       "sex", "height", "weight", "scaling", "heart-rate zones",
                       "hr zones", "zone bands", "custom zones", "zone 2", "max heart rate",
                       "calories", "background image"]
        ),
        SettingsSearchEntry(
            id: .units,
            title: "Units",
            keywords: ["measurement system", "metric", "imperial", "temperature",
                       "celsius", "fahrenheit", "kilograms", "pounds", "effort scale"]
        ),
        SettingsSearchEntry(
            id: .streak,
            title: "Streak",
            keywords: ["current streak", "longest streak", "days worn", "consistency"]
        ),
        SettingsSearchEntry(
            id: .appearance,
            title: "Appearance",
            keywords: ["language", "theme", "dark mode", "light mode", "accent colour",
                       "chart colours", "app icon", "reduce motion", "day-cycle background",
                       "sky behind cards", "transparent cards", "card transparency",
                       "breathing coach tile", "sleep chart", "trend charts", "preset",
                       "Liquid Today"]
        ),
        SettingsSearchEntry(
            id: .strap,
            title: "Strap",
            keywords: ["bluetooth", "pairing", "strap log", "strap name", "rename",
                       "live activity", "lock screen", "dynamic island"]
        ),
        SettingsSearchEntry(
            id: .hrv,
            title: "HRV",
            keywords: ["continuous HRV capture", "HRV window", "overnight only",
                       "beat-to-beat", "R-R", "deep sleep", "whole night"]
        ),
        SettingsSearchEntry(
            id: .recovery,
            title: "Recovery",
            keywords: ["charge", "baseline", "recalibrate", "re-learn", "HRV",
                       "resting heart rate"]
        ),
        SettingsSearchEntry(
            id: .testCentre,
            title: "Test Centre",
            keywords: ["diagnostics", "bug report", "strap log", "scheduled export",
                       "experimental probes"]
        ),
        SettingsSearchEntry(
            id: .features,
            title: "Features",
            keywords: ["hydration tracking", "auto-detect workouts", "journal reminder",
                       "keep screen on", "optional trackers"]
        ),
        SettingsSearchEntry(
            id: .liveSessions,
            // The section header's own wording, which is already a translated key — a search result
            // labelled differently from the card it lands on would read as a different thing.
            title: "Experimental · Live Sessions",
            keywords: ["guarded workout", "heart-rate band", "guardian", "beta",
                       "experimental"]
        ),
        SettingsSearchEntry(
            id: .sleepStaging,
            title: "Sleep staging",
            keywords: ["light", "deep", "REM", "staging recipe", "V1", "V2",
                       "motion-aware wake refinement"]
        ),
        SettingsSearchEntry(
            id: .experimentalWhoop5,
            title: "Experimental · WHOOP 5 / MG",
            keywords: ["deep-data unlock", "broadcast heart rate", "SpO₂ estimate",
                       "ECG", "MG", "WHOOP 5", "experimental probes"]
        ),
        SettingsSearchEntry(
            id: .diagnostics,
            title: "Diagnostics",
            keywords: ["export raw sensor data", "CSV", "decoded streams", "read-only"]
        ),
        SettingsSearchEntry(
            id: .backup,
            title: "Backup & restore",
            keywords: ["export", "import", "backup file", "noopbak", "restore",
                       "move to another machine", "sync to a folder"]
        ),
        SettingsSearchEntry(
            id: .about,
            title: "About",
            keywords: ["version", "how NOOP works", "how your scores work",
                       "Apple Watch data", "storage", "update check", "source code",
                       "GitHub", "licence"]
        ),
    ]

    /// The entries matching a raw query field, in catalog order (which is screen order — an unranked
    /// list keeps the layout the user already learned). An empty query returns everything.
    static func matching(_ query: String) -> [SettingsSearchEntry] {
        entries.filter { entry in
            SearchMatch.matches(query: query, in: entry.searchTerms)
        }
    }

    /// True when this section should stay on screen for the given query.
    static func section(_ id: SettingsSectionID, matches query: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else {
            // An unindexed section must stay VISIBLE while searching rather than vanish: a missing
            // catalog row is a maintenance slip, and hiding the section would turn it into a bug the
            // user experiences. The test above is what actually keeps this branch unreachable.
            return true
        }
        return SearchMatch.matches(query: query, in: entry.searchTerms)
    }
}

extension SettingsSearchEntry {
    /// Everything this entry can be found by: its translated name plus the English keywords. The
    /// `rawValue` of the id is deliberately NOT included — an internal identifier is not something a
    /// person types.
    var searchTerms: [String] { [String(localized: title)] + keywords }
}
