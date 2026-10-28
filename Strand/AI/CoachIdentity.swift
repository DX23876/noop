import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// On-device store for the coach identity (#R9): the small text (name / avatar ref / voice) as JSON in
/// UserDefaults, and any user photo as a file in Application Support — the same on-device-only posture as
/// `CoachConversationStore`. Singleton + `@Published` so the settings UI, the chat header, and the Today
/// entry all update live when the identity changes. Nothing here is ever sent anywhere.
@MainActor
final class CoachIdentityStore: ObservableObject {
    static let shared = CoachIdentityStore()

    @Published var identity: CoachIdentity {
        didSet { persist() }
    }

    private static let key = "coach.identity"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(CoachIdentity.self, from: data) {
            identity = decoded
        } else {
            identity = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Apply a supplied preset (Svea / Marv), replacing name + avatar + voice in one go. If the current
    /// avatar was a photo, that file is cleaned up.
    func applyPreset(_ preset: CoachIdentity) {
        deletePhotoIfNeeded(currentlyKeeping: preset.avatar)
        identity = preset
    }

    /// Set a curated symbol as the avatar, cleaning up a previous photo if there was one.
    func setPreset(symbol: String) {
        deletePhotoIfNeeded(currentlyKeeping: .preset(symbol))
        identity.avatar = .preset(symbol)
    }

    /// Rename the coach; a blank name is refused (clamped back to the current name) so the header never
    /// goes empty.
    func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        identity.name = trimmed
    }

    func setVoice(_ voice: CoachVoice) {
        identity.voice = voice
    }

    // MARK: - Photo storage (Application Support, on-device only)

    private static var photoDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func photoURL(_ filename: String) -> URL {
        photoDirectory.appendingPathComponent(filename)
    }

    /// Save a chosen photo's bytes to Application Support under a fresh filename and point the identity at
    /// it, deleting any previous coach photo. Returns false if the write fails (the identity is unchanged).
    @discardableResult
    func setPhoto(_ data: Data) -> Bool {
        let filename = "coach-avatar-\(UUID().uuidString).img"
        do {
            try data.write(to: Self.photoURL(filename), options: .atomic)
        } catch {
            return false
        }
        deletePhotoIfNeeded(currentlyKeeping: .photo(filename))
        identity.avatar = .photo(filename)
        return true
    }

    /// The raw bytes of the current photo avatar, or nil when the avatar is a preset symbol / the file is
    /// gone. Views turn this into a platform image; kept as `Data` so this type stays UIKit/AppKit-free.
    func photoData() -> Data? {
        guard case .photo(let filename) = identity.avatar else { return nil }
        return try? Data(contentsOf: Self.photoURL(filename))
    }

    /// Delete the on-disk photo file UNLESS the avatar we're keeping still references it. Called before
    /// every avatar change so old photos don't accumulate.
    private func deletePhotoIfNeeded(currentlyKeeping next: CoachAvatar) {
        guard case .photo(let old) = identity.avatar else { return }
        if case .photo(let keep) = next, keep == old { return }
        try? FileManager.default.removeItem(at: Self.photoURL(old))
    }
}
