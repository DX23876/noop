import XCTest
@testable import Strand

/// Pins the P R9 coach-identity model: the supplied presets, the prompt clause that carries the name +
/// tone, the Codable round-trip (including back-compat), and that the identity — not the persona — owns
/// the coach's name in the assembled system prompt. Pure where possible; the store touches UserDefaults.
@MainActor
final class CoachIdentityTests: XCTestCase {

    // MARK: - Presets

    func testSveaAndMarvArePresetsWithNamesAvatarsAndVoice() {
        XCTAssertEqual(CoachIdentity.svea.name, "Svea")
        XCTAssertEqual(CoachIdentity.svea.voice, .warm)
        XCTAssertEqual(CoachIdentity.marv.name, "Marv")
        XCTAssertEqual(CoachIdentity.marv.voice, .grounded)
        // Both default avatars are curated preset symbols (not photos).
        if case .preset = CoachIdentity.svea.avatar {} else { XCTFail("Svea should default to a preset symbol") }
        if case .preset = CoachIdentity.marv.avatar {} else { XCTFail("Marv should default to a preset symbol") }
    }

    func testDefaultIsSvea() {
        XCTAssertEqual(CoachIdentity.default, CoachIdentity.svea)
    }

    // MARK: - Prompt clause

    func testIdentityPreambleCarriesTheNameAndWarmNuance() {
        let text = CoachIdentity.svea.identityPreamble
        XCTAssertTrue(text.contains("You are Svea, the user's coach"))
        XCTAssertTrue(text.contains("warmer"), "the warm voice nudge must ride the clause")
    }

    func testGroundedNuanceDiffersAndNeutralAddsNothing() {
        XCTAssertTrue(CoachIdentity.marv.identityPreamble.contains("matter-of-fact"))
        let neutral = CoachIdentity(name: "Ada", avatar: .preset("sparkles"), voice: .neutral)
        XCTAssertEqual(neutral.identityPreamble, "You are Ada, the user's coach.",
                       "a neutral voice adds no tonal nudge")
    }

    func testBlankNameFallsBackGracefullyInThePreamble() {
        let blank = CoachIdentity(name: "  ", avatar: .preset("sparkles"), voice: .neutral)
        XCTAssertEqual(blank.identityPreamble, "You are the user's coach.")
    }

    // MARK: - Codable

    func testIdentityRoundTripsThroughJSON() throws {
        for original in [CoachIdentity.svea, CoachIdentity.marv,
                         CoachIdentity(name: "Ada", avatar: .photo("coach-avatar-x.img"), voice: .neutral)] {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CoachIdentity.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    func testAvatarRoundTripsBothCases() throws {
        for avatar in [CoachAvatar.preset("figure.run"), CoachAvatar.photo("f.img")] {
            let data = try JSONEncoder().encode(avatar)
            XCTAssertEqual(try JSONDecoder().decode(CoachAvatar.self, from: data), avatar)
        }
    }

    /// A partial blob (missing `voice`) still decodes, filling the gap from the default — the additive
    /// back-compat posture the rest of NOOP's on-device JSON uses.
    func testPartialBlobDecodesWithDefaults() throws {
        let json = #"{"name":"Kai","avatar":{"kind":"preset","value":"leaf.fill"}}"#
        let decoded = try JSONDecoder().decode(CoachIdentity.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Kai")
        XCTAssertEqual(decoded.voice, CoachIdentity.default.voice)
    }

    // MARK: - The identity owns the name in the assembled prompt (integration)

    func testSystemPromptLeadsWithTheIdentityNameNotThePersona() {
        // Set a distinctive identity + a persona; the assembled prompt must name the IDENTITY, and the
        // persona must contribute its STYLE without claiming to be the coach's name.
        CoachIdentityStore.shared.identity = CoachIdentity(name: "Nova", avatar: .preset("sparkles"), voice: .neutral)
        defer { CoachIdentityStore.shared.identity = .default }
        CoachPersona.set(.commander)
        defer { UserDefaults.standard.removeObject(forKey: CoachPersona.defaultsKey) }

        let engine = AICoachEngine(repo: Repository(deviceId: "test-identity-\(UUID().uuidString)"))
        let prompt = engine.systemPrompt
        XCTAssertTrue(prompt.contains("You are Nova, the user's coach"))
        XCTAssertTrue(prompt.contains("COACHING STYLE — Demanding"))
        XCTAssertFalse(prompt.contains("You are Commander"),
                       "the persona must not override the identity's name")
        // Ordering: the identity clause leads the persona style.
        let idRange = prompt.range(of: "You are Nova")
        let styleRange = prompt.range(of: "COACHING STYLE")
        XCTAssertNotNil(idRange); XCTAssertNotNil(styleRange)
        if let i = idRange, let s = styleRange { XCTAssertTrue(i.lowerBound < s.lowerBound) }
    }
}
