import Foundation

/// Stable, testable page order for the Settings landing screen: six groups, sorted by what a person
/// wants to get done rather than by how the app is built.
enum SettingsHubLayout {
    static let you: [SettingsPage] = [.profile, .goals]
    static let strapAndDevices: [SettingsPage] = [.strap, .batteryRecording, .strapActions]
    static let trainingAndEveryday: [SettingsPage] = [.training, .todayTrends, .notifications, .coach, .siri]
    static let display: [SettingsPage] = [.languageUnits, .appearance]
    static let data: [SettingsPage] = [.calculations, .dataBackup]
    static let help: [SettingsPage] = [.help, .lab, .about]

    static let allPages = you + strapAndDevices + trainingAndEveryday + display + data + help
}
