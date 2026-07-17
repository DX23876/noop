import XCTest
@testable import Strand

/// Pins `ChatMessage`'s Codable round-trip, in particular the P6 addition of `toolsUsed` (the evidence
/// chain): a transcript saved before this field existed must still decode, with an empty list rather
/// than a decode failure — the same back-compat pattern `date` already established for this type.
final class ChatMessageCodableTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testToolsUsedRoundTripsThroughEncoding() throws {
        let message = ChatMessage(role: .assistant, text: "You're at 72 today.",
                                  toolsUsed: ["get_readiness", "get_charge_drivers"])
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.toolsUsed, ["get_readiness", "get_charge_drivers"])
    }

    func testDefaultsToEmptyToolsUsedWhenNotSpecified() {
        let message = ChatMessage(role: .user, text: "How am I doing?")
        XCTAssertTrue(message.toolsUsed.isEmpty)
    }

    /// A transcript saved before `toolsUsed` existed has no such key at all — this must decode cleanly
    /// with an empty list, not throw, exactly like `date`'s own back-compat handling above it.
    func testPreExistingTranscriptWithoutToolsUsedKeyDecodesToEmptyList() throws {
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","role":"assistant","text":"Old reply.","date":719528400}
        """
        let decoded = try decoder.decode(ChatMessage.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.text, "Old reply.")
        XCTAssertTrue(decoded.toolsUsed.isEmpty)
    }

    func testEmptyToolsUsedRoundTripsAsEmptyNotNil() throws {
        let message = ChatMessage(role: .user, text: "Hi")
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.toolsUsed, [])
    }

    // MARK: - uniqueTools(from:) — the evidence chain's dedup/ordering (P6)

    func testUniqueToolsPreservesFirstCallOrder() {
        let tools = ChatMessage.uniqueTools(from: ["get_charge_drivers", "get_readiness"])
        XCTAssertEqual(tools, [.chargeDrivers, .readiness])
    }

    func testUniqueToolsDropsARepeatedCallButKeepsItsFirstPosition() {
        // get_readiness called in round 1 and again in round 3 (e.g. re-checked after a swap) must
        // appear once, at its FIRST position, not last.
        let tools = ChatMessage.uniqueTools(from: ["get_readiness", "get_recent_workouts", "get_readiness"])
        XCTAssertEqual(tools, [.readiness, .recentWorkouts])
    }

    func testUniqueToolsDropsUnrecognisedNamesRatherThanCrashingOrShowingARawIdentifier() {
        let tools = ChatMessage.uniqueTools(from: ["get_readiness", "some_future_tool_this_build_does_not_know"])
        XCTAssertEqual(tools, [.readiness])
    }

    func testUniqueToolsOfEmptyListIsEmpty() {
        XCTAssertTrue(ChatMessage.uniqueTools(from: []).isEmpty)
    }
}
