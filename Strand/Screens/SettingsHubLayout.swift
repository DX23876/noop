import Foundation

/// Stable, testable page order for the Settings landing screen: seven groups, sorted by what a person
/// wants to get done rather than by how the app is built.
enum SettingsHubLayout {
    /// Its own card above everything else: the page that answers "is this known, and what is coming".
    /// Alone on purpose, so it is one tap from the top without competing with Profile.
    static let project: [SettingsPage] = [.roadmap]
    static let you: [SettingsPage] = [.profile, .goals]
    static let strapAndDevices: [SettingsPage] = [.strap, .batteryRecording, .strapActions]
    static let trainingAndEveryday: [SettingsPage] = [.training, .todayTrends, .notifications, .coach, .siri]
    static let display: [SettingsPage] = [.languageUnits, .appearance]
    static let data: [SettingsPage] = [.calculations, .dataBackup]
    static let help: [SettingsPage] = [.help, .lab, .about]

    static let allPages = project + you + strapAndDevices + trainingAndEveryday + display + data + help
}
