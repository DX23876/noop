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

/// A first-level destination on the More hub. Categories navigate like Apple Settings rows instead of
/// expanding in place, so opening several areas can never turn the root back into a very long list.
enum MoreCategory: String, CaseIterable, Identifiable, Hashable {
    case analysis
    case healthBody
    case tools
    case data
    case app

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .analysis: return "Analysis"
        case .healthBody: return "Health & Body"
        case .tools: return "Tools"
        case .data: return "Data"
        case .app: return "App"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .analysis: return "Patterns, goals, journaling and your coach"
        case .healthBody: return "Training, body, energy and health signals"
        case .tools: return "Live heart rate, breathing and intervals"
        case .data: return "Sources, Apple Health, backup and portability"
        case .app: return "Alarms, automations, shortcuts and power"
        }
    }

    var icon: String {
        switch self {
        case .analysis: return "wand.and.sparkles"
        case .healthBody: return "heart.text.square.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .data: return "square.stack.3d.up.fill"
        case .app: return "slider.horizontal.3"
        }
    }

    var colorKey: String {
        switch self {
        case .analysis: return "insightsHub"
        case .healthBody: return "health"
        case .tools: return "intervals"
        case .data: return "fusedRecord"
        case .app: return "settings"
        }
    }
}

/// One category page in the More hierarchy.
struct MoreGroup: Identifiable {
    let category: MoreCategory
    let entries: [MoreEntry]

    var id: MoreCategory { category }
    var title: String { String(localized: category.title) }
}

/// The More tab's index, in screen order.
enum MoreCatalog {

    static let groups: [MoreGroup] = [
        MoreGroup(category: .analysis, entries: [
            // The full ranked feed the Today card shows one entry of. Listed first in Analysis because
            // it answers "what should I look at", which is the question this whole group serves.
            MoreEntry("Momentum", "bolt.horizontal", .momentum,
                      keywords: ["today", "priority", "what matters", "insights", "goals"]),
            // Renamed to match InsightsHubView's own ScreenScaffold title ("Insights") — the word
            // freed up once the section became "Analysis" and the old "Insights" row became "Journal".
            MoreEntry("Insights", "wand.and.sparkles", .insightsHub,
                      keywords: ["correlations", "weekly review", "patterns"]),
            // Renamed from "Intelligence": names what the screen actually explains (its own subtitle
            // is "NOOP scores your charge, effort and rest itself: on-device, no cloud.").
            MoreEntry("How Scoring Works", "brain.head.profile", .intelligence,
                      keywords: ["scoring", "charge", "effort", "rest", "on-device"]),
            MoreEntry("Goals", "target", .goalJourney,
                      keywords: ["goals", "weekly goal", "monthly goal", "journey", "plan", "progress", "coach"]),
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
        MoreGroup(category: .healthBody, entries: [
            MoreEntry("Training", "dumbbell.fill", .training,
                      keywords: ["workouts", "strength", "cardio", "training load", "sessions", "exercise"]),
            // Where every body measurement now lives. Next to Health because it answers the adjacent
            // question: Health is what the body is doing, Body is what it currently is.
            MoreEntry("Body", "figure.stand", .body,
                      keywords: ["weight", "body fat", "waist", "measurements", "tape", "navy",
                                 "circumference", "composition", "scale"]),
            // Directly after Body, because it consumes what Body records: the basal formula reads a
            // body-fat figure, and the balance check reads weigh-ins.
            MoreEntry("Energy", "flame.fill", .energyPlan,
                      keywords: ["calories", "tdee", "maintenance", "deficit", "intake", "bmr",
                                 "planning", "kcal", "diet", "surplus"]),
            MoreEntry("Health", "heart.text.square.fill", .health,
                      keywords: ["biometrics", "fitness age", "vitality", "skin temperature"]),
            // Renamed from "Lab Book": names the content directly (blood/BP/body numbers), not the
            // record-keeping metaphor.
            MoreEntry("Biomarkers", "books.vertical.fill", .labBook,
                      keywords: ["blood", "blood pressure", "lab results", "body composition"]),
            MoreEntry("Stress", "bolt.heart.fill", .stress,
                      keywords: ["strain", "load", "tension"]),
            // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
            // Renamed from "Rhythm": explicit that this is about heartbeat, not daily/circadian rhythm.
            MoreEntry("Beat Rhythm", "waveform.path", .rhythm,
                      keywords: ["beat-to-beat", "R-R", "regularity", "experimental"]),
            // Saved WHOOP MG readings, independent of the Devices card that starts one.
            MoreEntry("Saved ECGs", "waveform.path.ecg.rectangle", .ecg,
                      keywords: ["ECG", "EKG", "electrocardiogram", "WHOOP MG", "atrial fibrillation", "experimental"]),
        ]),
        MoreGroup(category: .tools, entries: [
            MoreEntry("Live", "waveform.path.ecg", .live,
                      keywords: ["heart rate", "BPM", "live console", "now"]),
            MoreEntry("Breathe", "wind", .breathe,
                      keywords: ["breathing", "box breathing", "calm", "biofeedback"]),
            MoreEntry("Intervals", "timer", .intervals,
                      keywords: ["interval timer", "rounds", "HIIT"]),
        ]),
        MoreGroup(category: .data, entries: [
            MoreEntry("Your Data, Fused", "square.stack.3d.up.fill", .fusedRecord,
                      keywords: ["merged record", "all sources", "one timeline"]),
            MoreEntry("Apple Health", "heart.fill", .appleHealth,
                      keywords: ["HealthKit", "import", "export", "sync", "iPhone"]),
            MoreEntry("Data Sources", "externaldrive.fill", .dataSources,
                      keywords: ["import", "WHOOP export", "CSV", "zip", "history", "Mi Band", "Xiaomi", "Mi Fitness"]),
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
        MoreGroup(category: .app, entries: [
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
            MoreEntry("Siri & Shortcuts", "mic.fill", .siriShortcuts,
                      keywords: ["voice", "App Intents", "automation"]),
            // #477 lives here rather than inside Settings: the strap-battery levers are the ones
            // people reach for when a strap is running down, so they get their own row.
            MoreEntry("Power saving", "battery.25", .powerSaving,
                      keywords: ["battery", "strap battery", "low power", "sampling"]),
        ]),
    ]

    /// Direct root rows stay one tap away instead of being buried under App.
    /// Goals sit on More's first level, above the categories, so they are one tap from the tab rather
    /// than two levels down under Analysis (goals plan §2a). The same entry stays in Analysis for browsing.
    static let goalsEntry = MoreEntry("Goals", "target", .goalJourney,
                                      keywords: ["goals", "weekly goal", "monthly goal", "journey", "progress"])

    static let rootEntries: [MoreEntry] = [
        MoreEntry("Settings", "gearshape.fill", .settings,
                  keywords: ["preferences", "options", "configuration"]),
        MoreEntry("Test Centre", "stethoscope", .testCentre,
                  keywords: ["diagnostics", "bug report", "strap log", "probes"]),
    ]

    /// Destinations consolidated behind Training/Data Sources remain globally searchable, so the new
    /// hierarchy removes duplication without making an existing screen undiscoverable.
    static let searchOnlyEntries: [MoreEntry] = [
        MoreEntry("Workouts", "figure.run", .workouts,
                  keywords: ["training", "sessions", "exercise", "activities"]),
        MoreEntry("Strength", "dumbbell.fill", .strength,
                  keywords: ["lifting", "hevy", "sets", "reps", "volume", "1rm", "gym"]),
        MoreEntry("Cardio", "figure.run.circle.fill", .cardio,
                  keywords: ["running", "cycling", "swimming", "pace", "distance", "endurance", "km", "speed", "rowing"]),
        MoreEntry("Training Load", "chart.bar.xaxis", .trainingLoad,
                  keywords: ["strength load", "cardio load", "session RPE", "sRPE", "acute", "chronic", "training stress"]),
        MoreEntry("Mi Band", "figure.walk.motion", .miBand,
                  keywords: ["Xiaomi", "Mi Fitness", "import"]),
    ]

    /// Every final destination searchable from the More root. Category pages themselves are excluded:
    /// search jumps directly to the useful endpoint.
    static var allEntries: [MoreEntry] {
        groups.flatMap(\.entries) + rootEntries + searchOnlyEntries
    }

    static func group(for category: MoreCategory) -> MoreGroup {
        groups.first(where: { $0.category == category })!
    }

    /// Rows matching a raw query, in screen order. An empty query returns everything, so a caller can
    /// pass the field's text straight through.
    static func matching(_ query: String) -> [MoreEntry] {
        allEntries.filter { SearchMatch.matches(query: query, in: $0.searchTerms) }
    }
}
#endif
