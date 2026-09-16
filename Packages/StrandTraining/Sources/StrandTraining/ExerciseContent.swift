import Foundation

public enum ExerciseProviderMode: String, Codable, CaseIterable, Sendable {
    /// Content bundled under a compatible licence and usable with no network.
    case bundled
    /// A catalogue file the wearer imports and is entitled to use.
    case localImport = "local_import"
    /// A compatible provider accessed only after the wearer enters its endpoint and personal key.
    case personalKey = "personal_key"
    /// A separately purchased, locally installed content pack.
    case licensedPack = "licensed_pack"
}

public struct ExerciseContentRights: Codable, Equatable, Sendable {
    public var provider: String
    public var licence: String
    public var attribution: String?
    public var allowsOfflineCache: Bool
    public var allowsRedistribution: Bool

    public init(provider: String, licence: String, attribution: String? = nil,
                allowsOfflineCache: Bool, allowsRedistribution: Bool) {
        self.provider = provider
        self.licence = licence
        self.attribution = attribution
        self.allowsOfflineCache = allowsOfflineCache
        self.allowsRedistribution = allowsRedistribution
    }
}

public struct ExerciseContentPage: Codable, Equatable, Sendable {
    public var exercises: [TrainingExercise]
    public var nextCursor: String?
    public var rights: ExerciseContentRights

    public init(exercises: [TrainingExercise], nextCursor: String? = nil,
                rights: ExerciseContentRights) {
        self.exercises = exercises
        self.nextCursor = nextCursor
        self.rights = rights
    }
}

public protocol ExerciseContentProvider: Sendable {
    var id: String { get }
    var mode: ExerciseProviderMode { get }
    var rights: ExerciseContentRights { get }
    func page(cursor: String?) async throws -> ExerciseContentPage
}

public enum ExerciseContentLimits {
    /// Evictable animation/video cache. Logged workouts only retain a small media identifier.
    public static let mediaCacheBytes = 200 * 1_024 * 1_024
    /// Provider metadata cache; the normalized exercise definitions remain in SQLite.
    public static let providerCacheBytes = 25 * 1_024 * 1_024
    public static let staleDraftDays = 7
}

/// A rights-neutral JSON envelope for catalogues the wearer imports. Media is referenced by id only;
/// the importer never downloads or embeds it and therefore cannot silently assume redistribution rights.
public struct ExerciseCatalogArchive: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var provider: String
    /// Where the content came from, exactly enough to re-derive it: repository, immutable revision and
    /// file. Optional, because a wearer-supplied catalogue need not have one.
    public var sourceRevision: String?
    /// SHA-256 of the upstream file this catalogue was generated from.
    public var sourceChecksum: String?
    public var rights: ExerciseContentRights
    public var exercises: [TrainingExercise]

    public init(formatVersion: Int = 1, provider: String,
                sourceRevision: String? = nil, sourceChecksum: String? = nil,
                rights: ExerciseContentRights, exercises: [TrainingExercise]) {
        self.formatVersion = formatVersion
        self.provider = provider
        self.sourceRevision = sourceRevision
        self.sourceChecksum = sourceChecksum
        self.rights = rights
        self.exercises = exercises
    }

    public static func decode(_ data: Data) throws -> ExerciseCatalogArchive {
        let archive = try JSONDecoder().decode(ExerciseCatalogArchive.self, from: data)
        guard archive.formatVersion == 1 else { throw ExerciseCatalogError.unsupportedVersion }
        guard !archive.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExerciseCatalogError.missingProvider
        }
        return archive
    }
}

public enum ExerciseCatalogError: Error, Equatable {
    case unsupportedVersion
    case missingProvider
}
