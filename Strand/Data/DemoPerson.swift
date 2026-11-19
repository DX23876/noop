import Foundation

/// Writes the demo account's body into the profile, on the Apple side.
///
/// The facts themselves are the shared dataset's (`DemoDataset.person`), so the iPhone and the emulator
/// show one demo person; only the writing is here, because the profile lives in this platform's defaults
/// and Android's in its own prefs file.
///
/// It refuses on a profile anybody has touched. A wearer who once started a debug build with `--demo-data`
/// must not find their own weight replaced by a synthetic one, and the three keys checked are the three the
/// profile treats as "somebody has said": the weight, the date of birth and the legacy age it mirrors.
///
/// Analysis migration required: no.
enum DemoPerson {
    static let weightKey = "profile.weightKg"
    static let dateOfBirthKey = "profile.dateOfBirth"
    static let legacyAgeKey = "profile.age"

    /// True when it wrote, false when it found a profile already there and left it alone.
    @MainActor
    @discardableResult
    static func applyIfUnset(to profile: ProfileStore, defaults: UserDefaults = .standard,
                             today: Date = Date()) -> Bool {
        guard [weightKey, dateOfBirthKey, legacyAgeKey].allSatisfy({ defaults.object(forKey: $0) == nil })
        else { return false }
        let person = DemoDataset.person(today: today)
        profile.dateOfBirth = ProfileStore.dateOfBirth(forAge: person.ageYears)
        profile.sex = person.sex
        profile.bodyFormulaSex = person.sex
        profile.heightCm = person.heightCm
        profile.waistCm = person.waistCm
        profile.weightKg = person.weightKg
        return true
    }
}
