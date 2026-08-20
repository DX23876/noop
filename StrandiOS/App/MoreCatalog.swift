#if os(iOS)
import Foundation

/// One row of the More tab's index, as data rather than as a hard-coded `MoreRow` in a view builder.
///
/// The rows were inline in `RootTabView.moreTab` until the index gained a search field: a filter needs
/// to read the rows (title, and the words someone might type instead of the title) before deciding
/// which to draw, and a `@ViewBuilder` closure cannot be read. Rendering from a catalog also means the
/// search results and the grouped list can never disagree about what exists.
struct MoreEntry: Identifiable, Hashable {
    /// Result-row and list label. A `LocalizedStringResource` (not `LocalizedStringKey`) because it
    /// must do BOTH jobs: the compiler still extracts the literal into the string catalog, and
    /// `String(localized:)` can resolve it at runtime for the search to match against.
    let title: LocalizedStringResource
    let icon: String
    let route: MoreDestination
    /// Alternative words for this row. These carry the search where the title cannot: the screen
    /// called "Explore" is what a person looks for as "metrics", and "Biomarkers" is where they land
    /// searching for "blood pressure".
    ///
    /// Deliberately plain `String`, i.e. English-only, while the `title` above is translated — so a
    /// non-English reader still finds every row by its own name, and the keywords add reach on top.
    /// Localizing them would put ~200 synonym keys through the string catalog, and a large share of
    /// them ("HealthKit", "ECG", "CSV", "HIIT", "noopbak") are identical in every language — which is
    /// precisely what `Tools/i18n_audit.py`'s echo gate exists to reject. A curated per-language alias
    /// list is a worthwhile thing to add later; machine-translating this one is not.
    let keywords: [String]

    init(_ title: LocalizedStringResource,
         _ icon: String,
         _ route: MoreDestination,
         keywords: [String] = []) {
        self.title = title
        self.icon = icon
        self.route = route
        self.keywords = keywords
    }

    /// The route identifies the row — no two rows lead to the same screen.
    var id: MoreDestination { route }

    static func == (lhs: MoreEntry, rhs: MoreEntry) -> Bool { lhs.route == rhs.route }
    func hash(into hasher: inout Hasher) { hasher.combine(route) }

    /// Everything this row can be found by: its translated name plus the English keywords.
    var searchTerms: [String] { [String(localized: title)] + keywords }
}

/// One collapsible group in the More index.
struct MoreGroup: Identifiable {
    /// The group's identity AND its displayed overline — and, critically, the key
    /// `MoreSectionPrefs` persists the open/closed choice under. These four strings are stored in
    /// UserDefaults on every existing installation, so they are not free to change or to translate.
    let title: String
    let entries: [MoreEntry]

    var id: String { title }
}

/// The More tab's index, in screen order.
enum MoreCatalog {

    static let groups: [MoreGroup] = [
        // "Analysis" (was "Insights", §7) — clearer group name. Coach is intentionally NOT listed
        // here: it's an action, reachable from the floating button, the Today tile and deep links,
        // not a place (its .coach destination stays registered so those entry points still push it).
        MoreGroup(title: "Analysis", entries: [
            // Renamed to match InsightsHubView's own ScreenScaffold title ("Insights") — the word
            // freed up once the section became "Analysis" and the old "Insights" row became "Journal".
            MoreEntry("Insights", "wand.and.sparkles", .insightsHub,
                      keywords: ["correlations", "weekly review", "patterns"]),
            // Renamed from "Intelligence": names what the screen actually explains (its own subtitle
            // is "NOOP scores your charge, effort and rest itself: on-device, no cloud.").
            MoreEntry("How Scoring Works", "brain.head.profile", .intelligence,
                      keywords: ["scoring", "charge", "effort", "rest", "on-device"]),
            MoreEntry("Goal & Journey", "target", .goalJourney,
                      keywords: ["goals", "plan", "progress", "coach"]),
            // Named "Journal" (was "Insights", colliding with this section's name — redesign bug §1):
            // this row opens the behaviour-logging + personal-experiments screen, the same view the
            // "Log journal" quick action opens.
            MoreEntry("Journal", "book.closed.fill", .insights,
                      keywords: ["log", "behaviour", "experiments", "caffeine", "alcohol"]),
            MoreEntry("Explore", "square.grid.2x2.fill", .explore,
                      keywords: ["metrics", "trends", "history", "every signal"]),
            MoreEntry("Compare", "rectangle.split.2x1.fill", .compare,
                      keywords: ["two metrics", "overlay", "correlation"]),
            // This row remains reachable while the Coach itself is off: it is where a person
            // connects a provider and explicitly turns the feature on again.
            MoreEntry("AI Coach", "sparkles", .coachSettings,
                      keywords: ["Svea", "chat", "API key", "provider", "model", "memory"]),
        ]),
        MoreGroup(title: "Body", entries: [
            MoreEntry("Live", "waveform.path.ecg", .live,
                      keywords: ["heart rate", "BPM", "live console", "now"]),
            MoreEntry("Workouts", "figure.run", .workouts,
                      keywords: ["training", "sessions", "exercise", "activities"]),
            MoreEntry("Health", "heart.text.square.fill", .health,
                      keywords: ["biometrics", "fitness age", "vitality", "skin temperature"]),
            // Renamed from "Lab Book": names the content directly (blood/BP/body numbers), not the
            // record-keeping metaphor.
            MoreEntry("Biomarkers", "books.vertical.fill", .labBook,
                      keywords: ["blood", "blood pressure", "lab results", "body composition"]),
            MoreEntry("Stress", "bolt.heart.fill", .stress,
                      keywords: ["strain", "load", "tension"]),
            MoreEntry("Breathe", "wind", .breathe,
                      keywords: ["breathing", "box breathing", "calm", "biofeedback"]),
            MoreEntry("Intervals", "timer", .intervals,
                      keywords: ["interval timer", "rounds", "HIIT"]),
            // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
            // Renamed from "Rhythm": explicit that this is about heartbeat, not daily/circadian rhythm.
            MoreEntry("Beat Rhythm", "waveform.path", .rhythm,
                      keywords: ["beat-to-beat", "R-R", "regularity", "experimental"]),
        ]),
        MoreGroup(title: "Data", entries: [
            MoreEntry("Your Data, Fused", "square.stack.3d.up.fill", .fusedRecord,
                      keywords: ["merged record", "all sources", "one timeline"]),
            MoreEntry("Apple Health", "heart.fill", .appleHealth,
                      keywords: ["HealthKit", "import", "export", "sync", "iPhone"]),
            MoreEntry("Mi Band", "figure.walk.motion", .miBand,
                      keywords: ["Xiaomi", "Mi Fitness", "import"]),
            MoreEntry("Data Sources", "externaldrive.fill", .dataSources,
                      keywords: ["import", "WHOOP export", "CSV", "zip", "history"]),
            MoreEntry("Backup & Sync", "externaldrive.fill.badge.icloud", .backupSync,
                      keywords: ["backup", "restore", "noopbak", "folder", "iCloud"]),
            // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut
            // reads the opt-in Documents/noop_sync.txt drop file).
            MoreEntry("Shortcuts Export", "square.and.arrow.up.fill", .shortcutsExport,
                      keywords: ["Siri Shortcut", "sideload", "drop file", "no HealthKit"]),
            // The plain 4.0 vs 5.0/MG capability grid — what NOOP reads live off each strap.
            MoreEntry("NOOP Limitations", "list.bullet.rectangle", .noopLimitations,
                      keywords: ["what works", "WHOOP 4.0", "WHOOP 5", "MG", "capabilities"]),
        ]),
        MoreGroup(title: "App", entries: [
            // #805/#811: the v7.3.1 #766 alarm consolidation moved Smart Alarm under a single
            // "Alarms" sidebar entry (RootView .smartAlarm) but the regression dropped the row
            // from the iPhone More list, leaving Alarms unreachable on iPhone. Restore it here
            // (route to SmartAlarmView, the cross-platform iOS/macOS surface).
            //
            // Notifications (RootView .notifications) is deliberately NOT added: that screen is
            // macOS-only (it picks which Mac apps tap your wrist via NSWorkspace, imports AppKit,
            // and project.yml excludes Screens/NotificationSettingsView.swift from the iOS target),
            // so it can't compile or apply on iPhone. iPhone's wrist-alert controls live on the
            // Automations screen instead. Its absence from the iPhone More list is correct.
            MoreEntry("Alarms", "alarm.fill", .alarms,
                      keywords: ["smart alarm", "wake", "wake-up window"]),
            MoreEntry("Automations", "wand.and.stars", .automations,
                      keywords: ["rules", "notifications", "wrist alerts", "reminders"]),
            // The Test Centre (the diagnostics + bug-report hub) gets a first-class home here, not
            // just buried in Settings, so the feedback loop is one tap from the More tab.
            MoreEntry("Test Centre", "stethoscope", .testCentre,
                      keywords: ["diagnostics", "bug report", "strap log", "probes"]),
            MoreEntry("Siri & Shortcuts", "mic.fill", .siriShortcuts,
                      keywords: ["voice", "App Intents", "automation"]),
            // #477 lives here rather than inside Settings: the strap-battery levers are the ones
            // people reach for when a strap is running down, so they get their own row.
            MoreEntry("Power saving", "battery.25", .powerSaving,
                      keywords: ["battery", "strap battery", "low power", "sampling"]),
            MoreEntry("Settings", "gearshape.fill", .settings,
                      keywords: ["preferences", "options", "configuration"]),
        ]),
    ]

    /// Every row, flattened — the search's haystack.
    static var allEntries: [MoreEntry] { groups.flatMap(\.entries) }

    /// Rows matching a raw query, in screen order. An empty query returns everything, so a caller can
    /// pass the field's text straight through.
    static func matching(_ query: String) -> [MoreEntry] {
        allEntries.filter { SearchMatch.matches(query: query, in: $0.searchTerms) }
    }
}
#endif
