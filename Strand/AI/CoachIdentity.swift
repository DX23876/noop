import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The coach's IDENTITY (#R9): its name, its avatar, and a light tonal nuance — the "who" the user is
/// talking to. This is a SEPARATE axis from `CoachPersona`, which is the "how" (the behavioural style:
/// protective / collaborative / demanding, from P13). A coach is an identity × a style: you can be Svea
/// coaching in the demanding style, or Marv in the protective one. The identity never touches behaviour
/// or the safety rails — only the name shown, the picture, and a small phrasing lean.
///
/// **Svea** and **Marv** are the two supplied presets (name + avatar + voice), fully editable — the
/// avatars are DELIBERATELY abstract/dezent design-system marks, and the user can swap in their own photo
/// (stored on-device only, like everything else in NOOP). Nothing here leaves the device.
struct CoachIdentity: Codable, Equatable {
    /// The coach's display name, shown in the chat header and on the Today entry. Never empty in practice
    /// (the store clamps a blank name back to the current preset's name).
    var name: String
    /// What the avatar is: a curated design-system symbol, or a user-supplied photo on disk.
    var avatar: CoachAvatar
    /// A small, editable phrasing lean layered UNDER the persona — deliberately not tied to gender in
    /// code; Svea defaults to `warm`, Marv to `grounded`, and either can be changed.
    var voice: CoachVoice

    init(name: String, avatar: CoachAvatar, voice: CoachVoice) {
        self.name = name
        self.avatar = avatar
        self.voice = voice
    }

    /// Back-compatible decode: a stored identity written before a field existed still loads, filling the
    /// missing field from the default (`.svea`) — the same additive posture the rest of NOOP's JSON uses.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? CoachIdentity.svea.name
        self.avatar = try c.decodeIfPresent(CoachAvatar.self, forKey: .avatar) ?? CoachIdentity.svea.avatar
        self.voice = (try c.decodeIfPresent(String.self, forKey: .voice)
            .flatMap(CoachVoice.init(rawValue:))) ?? CoachIdentity.svea.voice
    }

    private enum CodingKeys: String, CodingKey { case name, avatar, voice }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(avatar, forKey: .avatar)
        try c.encode(voice.rawValue, forKey: .voice)
    }

    // MARK: - Supplied presets

    /// The female-presented default coach. A warm phrasing lean, an abstract mark — a starting point, not
    /// a fixed character; every field is editable.
    static let svea = CoachIdentity(name: "Svea", avatar: .preset("figure.mind.and.body"), voice: .warm)
    /// The male-presented default coach. A grounded phrasing lean.
    static let marv = CoachIdentity(name: "Marv", avatar: .preset("figure.strengthtraining.traditional"), voice: .grounded)

    /// What a brand-new install starts on. Svea (warm) matches the app's existing supportive default tone
    /// (the persona also defaults to `friend`), and is one tap from Marv or a fully custom identity.
    static let `default` = svea

    /// The prompt clause that gives the model its name and phrasing lean (#R9 7.4/12). Prepended AHEAD of
    /// the persona preamble in `AICoachEngine.systemPrompt`, so the name is the identity's and the
    /// behaviour is the persona's — they never fight over "who you are". Pure/testable.
    var identityPreamble: String {
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = named.isEmpty ? "the user's coach" : "\(named), the user's coach"
        let lean = voice.nuance.isEmpty ? "" : " " + voice.nuance
        return "You are \(who).\(lean)"
    }
}

/// The coach's picture: a curated design-system symbol, or a photo the user supplied (referenced by a
/// filename in Application Support — the bytes never leave the device, and never ride the prompt).
enum CoachAvatar: Codable, Equatable {
    case preset(String)   // an SF Symbol name from `presetSymbols`
    case photo(String)    // a filename under the app's Application Support directory

    /// A small, tasteful set of abstract marks offered as standard avatars (#R9) — figures, not faces, in
    /// keeping with the design system. NOT a likeness of the presets' described appearance, which is a
    /// content line the project doesn't cross; the user supplies any real picture via photo upload.
    static let presetSymbols: [String] = [
        "figure.mind.and.body",
        "figure.strengthtraining.traditional",
        "figure.run",
        "figure.cooldown",
        "sparkles",
        "leaf.fill",
        "flame.fill",
        "bolt.heart.fill",
        "person.crop.circle.fill",
    ]

    // Codable as a tagged union so a future case can't silently corrupt an old blob.
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case preset, photo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let value = try c.decode(String.self, forKey: .value)
        switch kind {
        case .preset: self = .preset(value)
        case .photo:  self = .photo(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let s): try c.encode(Kind.preset, forKey: .kind); try c.encode(s, forKey: .value)
        case .photo(let s):  try c.encode(Kind.photo, forKey: .kind); try c.encode(s, forKey: .value)
        }
    }
}

/// The phrasing lean an identity carries — layered UNDER the behavioural persona, so it nudges tone only,
/// never what the coach decides. Deliberately gender-neutral as code: presets seed it, the user owns it.
enum CoachVoice: String, Codable, CaseIterable, Identifiable {
    case warm, grounded, neutral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .warm:     return "Warm"
        case .grounded: return "Grounded"
        case .neutral:  return "Neutral"
        }
    }

    /// The one-line tonal nudge added to the prompt. Empty for `neutral` (the persona's own voice stands).
    var nuance: String {
        switch self {
        case .warm:
            return "Lean a little warmer and more encouraging in how you phrase things — without going soft on the substance."
        case .grounded:
            return "Lean a little more matter-of-fact and steady in how you phrase things — without going cold."
        case .neutral:
            return ""
        }
    }
}

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
