import Foundation

/// Stable, testable page order for the Settings landing screen.
enum SettingsHubLayout {
    static let personal: [SettingsPage] = [.profile, .units, .appearance]
    static let trainingAndDevices: [SettingsPage] = [.training, .strap, .features]
    static let healthAndData: [SettingsPage] = [.recoverySleep, .dataBackup]
    static let support: [SettingsPage] = [.advanced, .about]

    static let allPages = personal + trainingAndDevices + healthAndData + support
}
