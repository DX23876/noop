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

/// A source of exercise media. Views never learn where files come from, so a provider can be replaced
/// or withdrawn without touching exercises, routines, workouts or analytics.
@MainActor
protocol ExerciseMediaProvider: AnyObject {
    var providerId: String { get }
    var isAvailable: Bool { get }
    func media(for exercise: TrainingExercise) -> ExerciseMedia?
}

/// The always-present last resort. Training works without media, so "no provider" is a normal state
/// rather than an error.
@MainActor
final class NoMediaProvider: ExerciseMediaProvider {
    static let shared = NoMediaProvider()
    let providerId = "none"
    let isAvailable = false
    func media(for exercise: TrainingExercise) -> ExerciseMedia? { nil }
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
    /// Withdrawn centrally: the upstream's own `NOTICE.md` says cloning grants no licence to the
    /// media, so NOOP has no documented right to fetch it. The exercise DATA is MIT and ships offline;
    /// only the images and animations are gated. Remove an id here once a licence exists for it.
    static let withdrawnProviderIds: Set<String> = ["hasaneyldrm-exercises-dataset"]

    private let providers: [ExerciseMediaProvider]

    init(providers: [ExerciseMediaProvider] = [ExerciseMediaStore.shared]) {
        self.providers = providers + [NoMediaProvider.shared]
    }

    static func isWithdrawn(_ providerId: String) -> Bool {
        guard withdrawnProviderIds.contains(providerId) else { return false }
        #if DEBUG
        // A DEBUG build may opt back in for one launch with `--allow-withdrawn-media`, so the media
        // presentation can be exercised against a real pack on a development machine. Deliberately a
        // launch ARGUMENT rather than a setting: it cannot be switched on from inside the app, it does
        // not persist, and the whole branch is compiled out of Release — the shipped app stays withdrawn
        // until a licence exists for it. It grants no right to the files; it only stops NOOP hiding a
        // pack the developer has already placed on their own device.
        return !CommandLine.arguments.contains("--allow-withdrawn-media")
        #else
        return true
        #endif
    }

    func media(for exercise: TrainingExercise) -> ExerciseMedia? {
        for provider in providers where provider.isAvailable {
            if let media = provider.media(for: exercise) { return media }
        }
        return nil
    }
}
