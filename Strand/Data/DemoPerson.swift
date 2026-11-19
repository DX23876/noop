import Foundation

/// Writes the demo account's body into the profile, on the Apple side.
///
/// The facts themselves are the shared dataset's (`DemoDataset.person`), so the iPhone and the emulator
/// show one demo person; only the writing is here, because the profile lives in this platform's defaults
/// and Android's in its own prefs file.
///
/// It refuses on a profile anybody has filled in. A wearer who once started a debug build with
/// `--demo-data` must not find their own figures replaced by synthetic ones.
///
/// The two keys it asks about are the height and the cohort, and that choice is the whole point. The date
/// of birth, the age and the weight are all WRITTEN BY THE APP on a profile nobody has touched: the #146
/// migration anchors a date of birth from the age-30 default the first time the profile is read, which
/// happens before this runs, and the weigh-in sync copies the newest weight across. Checking those keys
/// looked right and refused every time (seen on 2026-11-19: age 30, no height, no sex, and a demo whose
/// calorie goal still had no formula burn to start from). Nothing derives a height or a cohort, so those
/// two are the only keys that mean somebody actually said who this is.
///
/// Analysis migration required: no.
enum DemoPerson {
    /// The two keys nothing but the wearer ever writes.
    static let saidKeys = ["profile.heightCm", "profile.sex"]

    /// True when it wrote, false when it found a profile already there and left it alone.
    @MainActor
    @discardableResult
    static func applyIfUnset(to profile: ProfileStore, defaults: UserDefaults = .standard,
                             today: Date = Date()) -> Bool {
        guard saidKeys.allSatisfy({ defaults.object(forKey: $0) == nil }) else { return false }
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
