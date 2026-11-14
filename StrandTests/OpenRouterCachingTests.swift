import XCTest
@testable import Strand

/// The wire SHAPE of the cached system block. What this cannot pin is whether caching actually engages:
/// `AnthropicCaching` notes that a prefix under the model's minimum cacheable length silently does
/// nothing at all — no error, no warning, no saving. That half is verified by sending two real turns
/// through OpenRouter on an Anthropic model and reading `cacheReadTokens` in the Coach's usage card.
final class OpenRouterCachingTests: XCTestCase {

    private let prompt = "You are a coach."

    func testAnAnthropicModelGetsAContentPartCarryingTheBreakpoint() throws {
        let message = OpenRouterCaching.systemMessage(prompt, model: "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(message["role"] as? String, "system")

        let parts = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1, "one breakpoint, on the whole system block")
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, prompt, "the prompt itself must not be altered")
        XCTAssertEqual((parts[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
    }

    /// Vendor-suffixed and variant ids keep the `anthropic/` prefix — `anthropic/claude-opus-5-fast` is a
    /// real catalogue id — so they must be recognised too.
    func testAnthropicVariantIdsAreStillRecognised() {
        XCTAssertTrue(OpenRouterCaching.supportsCacheControl(model: "anthropic/claude-opus-5-fast"))
        XCTAssertTrue(OpenRouterCaching.supportsCacheControl(model: "anthropic/claude-sonnet-4.6:beta"))
    }

    /// Everything else keeps the plain-string form, byte-identical to what was sent before this existed.
    /// OpenAI-family models cache automatically and report `cached_tokens` back; a marker there would be
    /// a change to a request shape that is already working.
    func testEveryOtherModelKeepsThePlainStringForm() {
        for model in ["openai/gpt-4o-mini", "moonshotai/kimi-k3", "google/gemini-3.1-flash", ""] {
            let message = OpenRouterCaching.systemMessage(prompt, model: model)
            XCTAssertEqual(message["content"] as? String, prompt, "unchanged for \(model)")
            XCTAssertNil(message["content"] as? [[String: Any]], "no parts array for \(model)")
        }
    }

    /// The two loops share one concrete implementation on `OpenRouterClient`, so a future change cannot
    /// make the streaming path cache while the tool path does not (or the reverse).
    func testTheToolAndStreamingLoopsBuildTheSameSystemMessage() throws {
        let client = OpenRouterClient()
        let viaClient = client.systemMessage(prompt, model: "anthropic/claude-sonnet-4.6")
        let direct = OpenRouterCaching.systemMessage(prompt, model: "anthropic/claude-sonnet-4.6")

        let a = try XCTUnwrap(viaClient["content"] as? [[String: Any]])
        let b = try XCTUnwrap(direct["content"] as? [[String: Any]])
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a[0]["text"] as? String, b[0]["text"] as? String)
    }

    /// OpenAI's own client must not pick up the override: it conforms to the same protocols and takes
    /// the default.
    func testTheOpenAIClientTakesThePlainDefault() {
        let message = OpenAIClient().systemMessage(prompt, model: "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(message["content"] as? String, prompt,
                       "the model id is OpenRouter's namespace; OpenAI never sends a breakpoint")
    }
}
