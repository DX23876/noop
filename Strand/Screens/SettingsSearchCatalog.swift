import Foundation

/// Stable identity for each section on the Settings screen: a card inside a Settings page, or a whole
/// page that is its own screen (Coach, Notifications, …).
///
/// Exists so a section can be *addressed* — filtered by the Settings search field, and named as a
/// result row in the More tab's index search — without matching on its display title, which is
/// translated and therefore not a key.
enum SettingsSectionID: String, CaseIterable, Hashable, Sendable {
    case profile
    case goals
    case strap
    case steps
    case heartRateSharing
    case batteryRecording
    case strapActions
    case training
    case guidedTraining
    case todayLayout
    case todayCards
    case notifications
    case coach
    case siri
    case language
    case units
    case design
    case background
    case charts
    case motion
    case calculation
    case scoreRepair
    case backup
    case dataConnections
    case guides
    case testCentre
    case diagnostics
    case lab
    case labWhoop5
    case about
}

/// The Settings hierarchy (2026-10 reorganisation). Every control has exactly one page; other screens
/// may link to that page but never carry a copy of the control.
///
/// Six pages are complete screens of their own (`isStandaloneScreen`); the rest are built from cards
/// inside `SettingsView`.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case profile, goals
    case strap, batteryRecording, strapActions
    case training, todayTrends, notifications, coach, siri
    case languageUnits, appearance
    case calculations, dataBackup
    case help, lab, about

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .profile: return "Profile"
        case .goals: return "Goals"
        case .strap: return "Strap"
        case .batteryRecording: return "Battery & Recording"
        case .strapActions: return "Strap Actions"
        case .training: return "Training"
        case .todayTrends: return "Today & Trends"
        case .notifications: return "Notifications"
        case .coach: return "AI Coach"
        case .siri: return "Siri & Shortcuts"
        case .languageUnits: return "Language & Units"
        case .appearance: return "Appearance"
        case .calculations: return "Calculations"
        case .dataBackup: return "Data & Backup"
        case .help: return "Help & Diagnostics"
        case .lab: return "Lab"
        case .about: return "About"
        }
    }

    /// A short list of nouns, never a sentence: it names what is on the page.
    var subtitle: LocalizedStringResource {
        switch self {
        case .profile: return "Body, heart rate and fitness"
        case .goals: return "Number of goals, rest days and step goal"
        case .strap: return "Connection, steps and heart rate sharing"
        case .batteryRecording: return "Power saving and continuous HRV"
        case .strapActions: return "Double-tap, buzzes and heart-rate alerts"
        case .training: return "Sets, rest timers and weights"
        case .todayTrends: return "Cards, order and style"
        case .notifications: return "Lock Screen, wrist alerts and reminders"
        case .coach: return "Provider, model and memory"
        case .siri: return "Voice commands and shortcuts"
        case .languageUnits: return "Language, clock, week start and units"
        case .appearance: return "Theme, background, charts and motion"
        case .calculations: return "Day start, effort, HRV and sleep"
        case .dataBackup: return "Backup, Apple Health, imports and storage"
        case .help: return "Guides, Test Centre and bug reports"
        case .lab: return "Experimental features"
        case .about: return "Version, updates and source code"
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .goals: return "target"
        case .strap: return "antenna.radiowaves.left.and.right"
        case .batteryRecording: return "battery.75percent"
        case .strapActions: return "hand.tap.fill"
        case .training: return "dumbbell.fill"
        case .todayTrends: return "square.grid.2x2.fill"
        case .notifications: return "bell.badge.fill"
        case .coach: return "sparkles"
        case .siri: return "mic.fill"
        case .languageUnits: return "globe"
        case .appearance: return "circle.lefthalf.filled"
        case .calculations: return "function"
        case .dataBackup: return "externaldrive.fill"
        case .help: return "questionmark.circle.fill"
        case .lab: return "flask.fill"
        case .about: return "info.circle.fill"
        }
    }

    var colorKey: String {
        switch self {
        case .profile: return "settings.profile"
        case .goals: return "goalJourney"
        case .strap: return "settings.strap"
        case .batteryRecording: return "powerSaving"
        case .strapActions: return "automations"
        case .training: return "training"
        case .todayTrends: return "settings.features"
        case .notifications: return "notifications"
        case .coach: return "coachSettings"
        case .siri: return "siriShortcuts"
        case .languageUnits: return "settings.units"
        case .appearance: return "settings.appearance"
        case .calculations: return "intelligence"
        case .dataBackup: return "backupSync"
        case .help: return "testCentre"
        case .lab: return "settings.experimental"
        case .about: return "settings.about"
        }
    }

    /// True for the pages that are a complete screen of their own rather than cards inside
    /// `SettingsView`. `SettingsPageDestination` routes them.
    var isStandaloneScreen: Bool {
        switch self {
        case .goals, .batteryRecording, .strapActions, .notifications, .coach, .siri: return true
        default: return false
        }
    }

    var sectionIDs: [SettingsSectionID] {
        switch self {
        case .profile: return [.profile]
        case .goals: return [.goals]
        case .strap: return [.strap, .steps, .heartRateSharing]
        case .batteryRecording: return [.batteryRecording]
        case .strapActions: return [.strapActions]
        case .training: return [.training, .guidedTraining]
        case .todayTrends: return [.todayLayout, .todayCards]
        case .notifications: return [.notifications]
        case .coach: return [.coach]
        case .siri: return [.siri]
        case .languageUnits: return [.language, .units]
        case .appearance: return [.design, .background, .charts, .motion]
        case .calculations: return [.calculation, .scoreRepair]
        case .dataBackup: return [.backup, .dataConnections]
        case .help: return [.guides, .testCentre, .diagnostics]
        case .lab: return [.lab, .labWhoop5]
        case .about: return [.about]
        }
    }

    static func page(containing section: SettingsSectionID) -> SettingsPage {
        allCases.first(where: { $0.sectionIDs.contains(section) })!
    }
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
                       "sex", "height", "weight", "waist", "heart-rate zones", "hr zones", "zone bands",
                       "custom zones", "zone 2", "max heart rate", "VO2max", "activity level",
                       "calories", "body fat", "body measurements"]
        ),
        SettingsSearchEntry(
            id: .goals,
            title: "Goals",
            keywords: ["goal", "rest days", "step goal", "daily steps", "streak", "badges", "records",
                       "motivation", "week bar", "goal notifications"]
        ),
        SettingsSearchEntry(
            id: .strap,
            title: "Strap",
            keywords: ["bluetooth", "pairing", "connection", "re-scan", "disconnect", "strap log",
                       "strap name", "rename", "sync", "keep screen on"]
        ),
        SettingsSearchEntry(
            id: .steps,
            title: "Steps",
            keywords: ["step count", "step-count correction", "steps estimate", "calibration",
                       "too many steps", "WHOOP 4.0 steps"]
        ),
        SettingsSearchEntry(
            id: .heartRateSharing,
            title: "Heart rate sharing",
            keywords: ["broadcast", "heart-rate sensor", "Garmin", "Zwift", "Peloton", "treadmill",
                       "bike computer", "gym"]
        ),
        SettingsSearchEntry(
            id: .batteryRecording,
            title: "Battery & Recording",
            keywords: ["battery", "power saving", "low power", "strap battery", "low refresh",
                       "continuous HRV", "beat-to-beat", "R-R", "overnight only"]
        ),
        SettingsSearchEntry(
            id: .strapActions,
            title: "Strap Actions",
            keywords: ["double-tap", "haptics", "buzz", "vibration", "heart-rate ceiling",
                       "haptic coaching", "lock the Mac", "wear"]
        ),
        SettingsSearchEntry(
            id: .training,
            title: "Training",
            keywords: ["strength", "workout", "RPE", "RIR", "set effort", "session rating", "rest timer",
                       "warm-up", "rest-pause", "timer sound", "haptics", "vibration", "notification",
                       "keep screen on", "screen awake", "workout view", "exercise media",
                       "download media", "equipment", "kilograms", "weight unit", "weight step", "plates",
                       "double-tap"]
        ),
        SettingsSearchEntry(
            id: .guidedTraining,
            title: "Guided training",
            keywords: ["live session", "guarded workout", "heart-rate band", "auto-detect workouts",
                       "workout suggestions"]
        ),
        SettingsSearchEntry(
            id: .todayLayout,
            title: "Dashboard",
            keywords: ["dashboard style", "arrange dashboard", "Liquid Today", "trends slots",
                       "card order", "layout"]
        ),
        SettingsSearchEntry(
            id: .todayCards,
            title: "Today cards",
            keywords: ["water", "hydration", "journal", "journal card", "optional trackers"]
        ),
        SettingsSearchEntry(
            id: .notifications,
            title: "Notifications",
            keywords: ["live activity", "lock screen", "dynamic island", "wrist alerts", "inactivity",
                       "illness", "battery alerts", "sync reminder", "strain target", "training load alert",
                       "cycle awareness", "reminders"]
        ),
        SettingsSearchEntry(
            id: .coach,
            title: "AI Coach",
            keywords: ["Svea", "chat", "API key", "provider", "model", "memory"]
        ),
        SettingsSearchEntry(
            id: .siri,
            title: "Siri & Shortcuts",
            keywords: ["voice", "App Intents", "automation", "shortcut"]
        ),
        SettingsSearchEntry(
            id: .language,
            title: "Language",
            keywords: ["language", "clock", "12-hour", "24-hour", "week start", "Monday", "Sunday"]
        ),
        SettingsSearchEntry(
            id: .units,
            title: "Units",
            keywords: ["measurement system", "metric", "imperial", "distance", "pace", "temperature",
                       "celsius", "fahrenheit", "kilograms", "pounds", "skin temperature", "effort scale"]
        ),
        SettingsSearchEntry(
            id: .design,
            title: "Style",
            keywords: ["theme", "dark mode", "light mode", "preset", "accent colour", "app icon",
                       "coloured icons", "tab bar"]
        ),
        SettingsSearchEntry(
            id: .background,
            title: "Background",
            keywords: ["time-of-day sky", "day-cycle background", "motif", "sky behind cards",
                       "transparent cards", "card transparency", "custom photo", "background image"]
        ),
        SettingsSearchEntry(
            id: .charts,
            title: "Charts",
            keywords: ["chart colours", "sleep chart", "trend charts", "line", "bars"]
        ),
        SettingsSearchEntry(
            id: .motion,
            title: "Motion",
            keywords: ["reduce motion", "animation", "motion effect", "coach animation", "tilt"]
        ),
        SettingsSearchEntry(
            id: .calculation,
            title: "Calculations",
            keywords: ["day start", "day cycle", "midnight", "effort model", "Banister", "TRIMP",
                       "HRV window", "deep sleep", "sleep stage method", "wake check", "scoring"]
        ),
        SettingsSearchEntry(
            id: .scoreRepair,
            title: "If scores look wrong",
            keywords: ["recalibrate", "reset baseline", "re-learn", "charge baseline", "refresh today",
                       "recalculate", "21 days", "reanalysis", "scores stuck"]
        ),
        SettingsSearchEntry(
            id: .backup,
            title: "Backup",
            keywords: ["export", "import", "backup file", "noopbak", "restore",
                       "move to another machine", "sync to a folder", "auto-backup"]
        ),
        SettingsSearchEntry(
            id: .dataConnections,
            title: "Apple Health & imports",
            keywords: ["Apple Health", "HealthKit", "data sources", "WHOOP export", "CSV", "Mi Band",
                       "shortcuts export", "storage", "clean up"]
        ),
        SettingsSearchEntry(
            id: .guides,
            title: "Guides",
            keywords: ["how NOOP works", "how your scores work", "Apple Watch data", "limitations",
                       "what works", "help"]
        ),
        SettingsSearchEntry(
            id: .testCentre,
            title: "Test Centre",
            keywords: ["diagnostics", "bug report", "strap log", "scheduled export", "experimental probes"]
        ),
        SettingsSearchEntry(
            id: .diagnostics,
            title: "Diagnostics",
            keywords: ["export raw sensor data", "CSV", "decoded streams", "device info", "sideload"]
        ),
        SettingsSearchEntry(
            id: .lab,
            title: "Lab",
            keywords: ["experimental", "beta", "stress baseline", "training-based VO2max", "AgeLess",
                       "healthspan", "daily rhythm", "rhythm age", "CosinorAge", "blood oxygen", "SpO₂ estimate", "Oura"]
        ),
        SettingsSearchEntry(
            id: .labWhoop5,
            title: "Lab · WHOOP 5 / MG",
            keywords: ["deep-data unlock", "R22", "ECG", "MG", "WHOOP 5", "protocol probes",
                       "frame capture"]
        ),
        SettingsSearchEntry(
            id: .about,
            title: "About",
            keywords: ["version", "what's new", "update check", "source code", "GitHub", "licence",
                       "acknowledgements", "medical"]
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
    var page: SettingsPage { SettingsPage.page(containing: id) }
}
