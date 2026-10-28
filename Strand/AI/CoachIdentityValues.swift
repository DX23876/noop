import Foundation

/// The coach's IDENTITY (#R9): its name, its avatar, and a light tonal nuance — the "who" the user is
/// talking to. This is a SEPARATE axis from `CoachPersona`, which is the "how" (the behavioural style:
/// protective / collaborative / demanding, from P13). A coach is an identity × a style: you can be Svea
/// coaching in the demanding style, or Marv in the protective one. The identity never touches behaviour
/// or the safety rails — only the name shown, the picture, and a small phrasing lean.
///
/// **Svea** and **Marv** are the two supplied presets (name + avatar + voice), fully editable — each with
/// a bundled preset photo (#R-avatar-photos), or the user can pick an abstract design-system symbol
/// instead, or swap in their own photo (stored on-device only, like everything else in NOOP). Nothing
/// here ever leaves the device.
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

    /// The female-presented default coach. A warm phrasing lean, a bundled photo (#R-avatar-photos) — a
    /// starting point, not a fixed character; every field, including the avatar itself, is editable.
    static let svea = CoachIdentity(name: "Svea", avatar: .bundled("svea-avatar"), voice: .warm)
    /// The male-presented default coach. A grounded phrasing lean.
    static let marv = CoachIdentity(name: "Marv", avatar: .bundled("marv-avatar"), voice: .grounded)

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

/// The coach's picture: a curated design-system symbol, a bundled preset photo shipped with the app, or
/// a photo the user supplied themselves (referenced by a filename in Application Support — the bytes
/// never leave the device, and never ride the prompt).
enum CoachAvatar: Codable, Equatable {
    case preset(String)   // an SF Symbol name from `presetSymbols`
    case bundled(String)  // an app-bundle image asset name (#R-avatar-photos) — e.g. the Svea/Marv presets
    case photo(String)    // a filename under the app's Application Support directory

    /// A small, tasteful set of abstract marks offered as standard avatars (#R9) — figures, not faces, in
    /// keeping with the design system. Offered alongside the bundled Svea/Marv photos and a user's own
    /// upload as alternative choices for a fully custom identity.
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
    private enum Kind: String, Codable { case preset, bundled, photo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let value = try c.decode(String.self, forKey: .value)
        switch kind {
        case .preset:  self = .preset(value)
        case .bundled: self = .bundled(value)
        case .photo:   self = .photo(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let s):  try c.encode(Kind.preset, forKey: .kind); try c.encode(s, forKey: .value)
        case .bundled(let s): try c.encode(Kind.bundled, forKey: .kind); try c.encode(s, forKey: .value)
        case .photo(let s):   try c.encode(Kind.photo, forKey: .kind); try c.encode(s, forKey: .value)
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
