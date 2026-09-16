import Foundation
import StrandTraining

/// One playable or displayable file for an exercise, addressed only by NOOP's own exercise identity.
struct ExerciseMedia: Equatable, Sendable {
    enum Kind: String, Sendable {
        case animation
        case video
        case image
    }

    let url: URL
    let kind: Kind

    /// Classifies by file extension; an unknown extension is treated as a still image, which is the
    /// presentation that always works.
    init(url: URL) {
        self.url = url
        switch url.pathExtension.lowercased() {
        case "gif", "apng": kind = .animation
        case "mp4", "mov", "m4v": kind = .video
        default: kind = .image
        }
    }

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// Which rendition a surface wants. Lists and thumbnails ask for a still — cheap to decode and small —
/// while the exercise detail and the exercise being logged ask for the animation.
enum ExerciseMediaVariant: Sendable {
    case animation
    case still
}

/// A source of exercise media. Views never learn where files come from, so a provider can be replaced
/// or withdrawn without touching exercises, routines, workouts or analytics.
@MainActor
protocol ExerciseMediaProvider: AnyObject {
    var providerId: String { get }
    var isAvailable: Bool { get }
    func media(for exercise: TrainingExercise, variant: ExerciseMediaVariant) -> ExerciseMedia?
}

/// The always-present last resort. Training works without media, so "no provider" is a normal state
/// rather than an error.
@MainActor
final class NoMediaProvider: ExerciseMediaProvider {
    static let shared = NoMediaProvider()
    let providerId = "none"
    let isAvailable = false
    func media(for exercise: TrainingExercise, variant: ExerciseMediaVariant) -> ExerciseMedia? { nil }
}

/// Resolves media through the first provider that has it, and owns the central kill switch.
///
/// `withdrawnProviderIds` is how a provider is disabled for everyone — a licence change, a withdrawn
/// upstream, a corrupt release. A withdrawn provider reports nothing and cannot be downloaded; the
/// presentation falls back to image, then muscle information, then text, and no training function is
/// blocked.
@MainActor
final class ExerciseMediaRegistry: ObservableObject {
    static let shared = ExerciseMediaRegistry()
    /// Providers disabled for everyone. Currently none: the exercise media pack is never bundled and is
    /// only fetched when the wearer confirms a download after seeing its source, size and the rights
    /// holder's conditions (© Gym visual, attribution kept, personal non-commercial use). Add an id here
    /// to withdraw a provider again without touching exercises, routines or history.
    static let withdrawnProviderIds: Set<String> = []

    private let providers: [ExerciseMediaProvider]

    init(providers: [ExerciseMediaProvider] = [ExerciseMediaStore.shared]) {
        self.providers = providers + [NoMediaProvider.shared]
    }

    static func isWithdrawn(_ providerId: String) -> Bool {
        withdrawnProviderIds.contains(providerId)
    }

    func media(for exercise: TrainingExercise, variant: ExerciseMediaVariant = .animation) -> ExerciseMedia? {
        for provider in providers where provider.isAvailable {
            if let media = provider.media(for: exercise, variant: variant) { return media }
        }
        return nil
    }
}
