import Foundation

// ExerciseCatalogSeed.swift — when the shipped exercise catalogue has to be written into the store.
//
// This was four lines of `if` inside `Repository.prepareNativeTraining`, and one of them was a bug
// that cost a wearer their entire exercise library: the "seeded at version N" flag was written even
// when the write it recorded had thrown. One transient failure — a busy database, a migration still
// running — and the flag said the catalogue was there while the table was empty. Nothing re-ran,
// because the flag was the only thing anyone asked. It was reported as a library that "could not
// load anything", with the exercise typed in by hand.
//
// The decision lives here, as a pure function over four integers, for one reason: it is the part
// that was wrong, and in the repository it was reachable only through a real database, a real
// UserDefaults and a launch. Here `swift test` can state every case in a line.
//
// The effect — writing the rows, writing the flags — stays in the repository, where it belongs.
public enum ExerciseCatalogSeed {

    /// What the caller should write.
    public enum Decision: Equatable, Sendable {
        /// The catalogue is current and complete. Write nothing.
        case none
        /// Write the starter definitions AND the bundled catalogue.
        case full(Reason)
        /// Only the starter definitions changed; the bundled catalogue is current and present.
        case starterOnly
    }

    /// Why a full seed is being asked for. Carried so the caller can say which of the two happened —
    /// a version bump is routine and silent, an incomplete catalogue is evidence of the failure above
    /// and worth a line in the log.
    public enum Reason: Equatable, Sendable {
        case newContentVersion
        case incomplete(stored: Int, expected: Int)
    }

    /// - Parameters:
    ///   - seededContentVersion: the bundled-catalogue version the last SUCCESSFUL seed recorded.
    ///   - seededStarterVersion: the same for the starter definitions.
    ///   - storedCount: how many definitions the store holds, or nil when that could not be read.
    ///   - shippedCount: how many distinct ids the app ships (starter ∪ bundled).
    ///   - contentVersion: the bundled catalogue's current version.
    ///   - starterVersion: the starter catalogue's current version.
    public static func decide(seededContentVersion: Int,
                              seededStarterVersion: Int,
                              storedCount: Int?,
                              shippedCount: Int,
                              contentVersion: Int = BundledExerciseCatalog.contentVersion,
                              starterVersion: Int = TrainingStarterCatalog.contentVersion) -> Decision {
        if seededContentVersion < contentVersion { return .full(.newContentVersion) }

        // A flag is a record of intent; the count is the fact. Definitions are never deleted — nothing
        // in the app offers it — so the stored count only ever grows past the shipped floor, and a
        // count below it means a seed that did not land rather than a wearer who tidied up.
        //
        // An UNREADABLE count is treated as intact on purpose: re-seeding 1,300 rows on every launch
        // because a read failed would turn a transient fault into a permanent cost, and the next
        // launch (or the next version bump) settles it anyway.
        if let storedCount, storedCount < shippedCount {
            return .full(.incomplete(stored: storedCount, expected: shippedCount))
        }

        if seededStarterVersion < starterVersion { return .starterOnly }
        return .none
    }
}
