import SwiftUI

/// The single Appearance preference for colourful navigation chrome and primary controls.
/// It deliberately does not affect data visualisations, status colours, or destructive actions.
public enum AppleInspiredColorsPrefs {
    /// Keep the existing key so upgrading users retain their current "App icon colors" choice.
    public static let enabledKey = "noop.moreRowAppleHealthColors"
    public static let defaultEnabled = true
}

/// Semantic roles keep the Apple-inspired palette testable without comparing resolved SwiftUI colours.
public enum AppleInspiredColorRole: String, Equatable, Sendable {
    case blue, teal, cyan, indigo, purple, pink, red, orange, yellow, green, mint, brown, gray

    public var color: Color {
        switch self {
        case .blue: return .systemBlue
        case .teal: return .systemTeal
        case .cyan: return .systemCyan
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .brown: return .systemBrown
        case .gray: return .systemGray
        }
    }
}

/// Central semantic palette for leading identity icons and their primary controls. IDs describe a
/// stable meaning rather than an SF Symbol, so changing a glyph cannot accidentally change its colour.
public enum AppleInspiredColors {
    public static func role(for id: String) -> AppleInspiredColorRole {
        switch id {
        // Navigation and feature families
        case "insightsHub", "coach", "coachSettings", "settings.appearance", "automations",
             "notifications": return .purple
        case "intelligence", "labBook", "sleep", "settings.sleep", "coach.settings.memory": return .indigo
        case "goalJourney", "alarms", "settings.units", "training", "caffeine": return .orange
        case "insights", "journal": return .orange
        case "coach.settings.usage": return .brown
        case "explore", "fusedRecord", "backupSync", "shortcutsExport", "settings.profile", "settings.controls",
             "dashboardEditor", "keyMetricsEditor", "updates": return .blue
        case "compare", "dataSources", "settings", "settings.diagnostics", "settings.about",
             "coach.settings.systemPrompt": return .gray
        case "live", "rhythm", "coach.goal.strength", "coach.info.limits", "coach.persona.commander",
             "coach.firstUse.notMedical": return .red
        case "health", "settings.recovery", "healthControls", "appleHealth", "siriShortcuts",
             "coach.preset.supportive", "coach.persona.friend", "coach.goal.recovery": return .pink
        case "workouts", "coach.settings.coaching", "journey.nextStep", "coach.goalJourney.progress",
             "coach.goal.run": return .green
        case "stress", "settings.power": return .yellow
        case "breathe", "breathing": return .mint
        case "intervals", "settings.features", "coach.settings.autoSummarize", "hrv": return .cyan
        case "miBand", "settings.strap", "deviceSetup", "coach.settings.entry": return .green
        case "testCentre", "settings.testCentre", "coach.settings.privacy", "coach.persona.guardian": return .teal
        case "settings.liveSessions", "settings.experimental", "coach.settings.howItWorks",
             "coach.goal.sleep": return .indigo

        // Coach and goal details
        case "chat.header.newChat", "coach.firstUse.dataConsent": return .green
        case "chat.header.menu", "coach.preset.onDemand": return .gray
        case "chat.notConnected", "coach.settings.presets", "coach.goal.custom": return .purple
        case "coach.settings.connection", "coach.settings.dataAccess", "coach.info.providerModel",
             "coach.firstUse.model": return .blue
        case "coach.settings.goalJourney", "coach.settings.proactive", "coach.goalJourney.newGoal",
             "coach.goal.consistency": return .orange
        case "coach.info.howItWorks": return .purple
        case "coach.info.whatIsShared", "coach.settings.verbosity", "coach.firstUse.support",
             "coach.goal.weight": return .teal
        case "coach.info.whyModelMatters", "coach.settings.memoryBar": return .indigo
        case "coach.goal.stress": return .yellow

        // Settings sections retain their existing symbol-keyed API.
        case "person.crop.circle", "externaldrive.fill": return .blue
        case "person.fill", "shield.lefthalf.filled", "bed.double.fill": return .indigo
        case "ruler": return .orange
        case "circle.lefthalf.filled", "flask.fill": return .purple
        case "antenna.radiowaves.left.and.right": return .green
        case "battery.25": return .yellow
        case "heart.text.square": return .red
        case "testtube.2": return .teal
        case "drop.fill": return .cyan
        case "doc.text.magnifyingglass", "info.circle.fill": return .gray

        default: return .blue
        }
    }

    public static func color(for id: String, enabled: Bool = true) -> Color {
        enabled ? role(for: id).color : StrandPalette.accent
    }
}

private struct AppleInspiredTintModifier: ViewModifier {
    let id: String
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var enabled = AppleInspiredColorsPrefs.defaultEnabled

    func body(content: Content) -> some View {
        let color = AppleInspiredColors.color(for: id, enabled: enabled)
        content
            .tint(color)
            .environment(\.appleInspiredControlColor, color)
    }
}

private struct AppleInspiredControlColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The colour custom StrandDesign controls should use when an `appleInspiredTint` wraps them.
    var appleInspiredControlColor: Color? {
        get { self[AppleInspiredControlColorKey.self] }
        set { self[AppleInspiredControlColorKey.self] = newValue }
    }
}

private struct AppleInspiredForegroundModifier: ViewModifier {
    let id: String
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var enabled = AppleInspiredColorsPrefs.defaultEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(AppleInspiredColors.color(for: id, enabled: enabled))
    }
}

public extension View {
    /// Applies a preference-reactive tint to a primary control. Disabled states remain native.
    func appleInspiredTint(_ id: String) -> some View {
        modifier(AppleInspiredTintModifier(id: id))
    }

    /// Applies the same preference-reactive colour to one identity symbol or already-coloured action.
    /// Do not attach this to a composite `Label`: ordinary menu text intentionally remains neutral.
    func appleInspiredForeground(_ id: String) -> some View {
        modifier(AppleInspiredForegroundModifier(id: id))
    }
}
