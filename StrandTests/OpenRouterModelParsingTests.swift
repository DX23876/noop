import XCTest
@testable import Strand

/// Pins `OpenRouterClient.parseModelDetails`/`parseChatContent` against a REAL, frozen sample of
/// OpenRouter's `/models` response (fetched live via `curl` while writing this, not invented) — three
/// representative rows: a tool-capable paid model, a model with no tool support, and a free-tier model.
/// The exact field shapes below (`pricing.prompt` as a decimal STRING, `supported_parameters` as a flat
/// array containing `"tools"`) matter because they're easy to get wrong from memory.
final class OpenRouterModelParsingTests: XCTestCase {

    private let client = OpenRouterClient()

    /// Verbatim transcription of three rows from a live `GET https://openrouter.ai/api/v1/models`
    /// response — trimmed to the fields the parser reads.
    private let sampleBody: [String: Any] = [
        "data": [
            [
                "id": "moonshotai/kimi-k3",
                "name": "MoonshotAI: Kimi K3",
                "context_length": 1_048_576,
                "pricing": ["prompt": "0.000003", "completion": "0.000015", "input_cache_read": "0.0000003"],
                "supported_parameters": ["tools", "tool_choice", "reasoning", "max_tokens"]
            ],
            [
                "id": "google/gemini-3.1-flash-lite-image",
                "name": "Google: Nano Banana 2 Lite (Gemini 3.1 Flash Lite Image)",
                "context_length": 65_536,
                "pricing": ["prompt": "0.00000025", "completion": "0.0000015", "image_output": "0.00003"],
                "supported_parameters": ["max_tokens", "response_format"]
            ],
            [
                "id": "tencent/hy3:free",
                "name": "Tencent: Hy3 (free)",
                "context_length": 262_144,
                "pricing": ["prompt": "0", "completion": "0"],
                "supported_parameters": ["tools", "max_tokens"]
            ]
        ]
    ]

    // MARK: - parseModelDetails

    func testParsesAllThreeRows() {
        let models = client.parseModelDetails(sampleBody)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models.map { $0.id }, [
            "moonshotai/kimi-k3", "google/gemini-3.1-flash-lite-image", "tencent/hy3:free"
        ])
    }

    func testToolCapabilityReadsFromSupportedParameters() {
        let models = client.parseModelDetails(sampleBody)
        XCTAssertEqual(models.first { $0.id == "moonshotai/kimi-k3" }?.supportsTools, true)
        XCTAssertEqual(models.first { $0.id == "google/gemini-3.1-flash-lite-image" }?.supportsTools, false)
        XCTAssertEqual(models.first { $0.id == "tencent/hy3:free" }?.supportsTools, true)
    }

    func testPriceIsScaledToPerMillionTokens() {
        let kimi = client.parseModelDetails(sampleBody).first { $0.id == "moonshotai/kimi-k3" }
        // "0.000003" USD/token × 1,000,000 = $3.00 / 1M tokens.
        XCTAssertEqual(kimi?.promptPricePerMillion ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(kimi?.completionPricePerMillion ?? -1, 15.0, accuracy: 0.0001)
    }

    func testFreeModelPricesAsZeroNotNil() {
        let free = client.parseModelDetails(sampleBody).first { $0.id == "tencent/hy3:free" }
        // "0" must parse to 0.0, not be dropped as missing — a free model is a real price, not an
        // absent one.
        XCTAssertEqual(free?.promptPricePerMillion, 0)
        XCTAssertEqual(free?.completionPricePerMillion, 0)
    }

    func testContextLengthAndNameCarryThrough() {
        let img = client.parseModelDetails(sampleBody).first { $0.id == "google/gemini-3.1-flash-lite-image" }
        XCTAssertEqual(img?.contextLength, 65_536)
        XCTAssertEqual(img?.name, "Google: Nano Banana 2 Lite (Gemini 3.1 Flash Lite Image)")
    }

    func testRowsMissingAnIdAreDropped() {
        let models = client.parseModelDetails(["data": [["name": "no id here"]]])
        XCTAssertTrue(models.isEmpty)
    }

    func testMissingDataKeyReturnsEmpty() {
        XCTAssertTrue(client.parseModelDetails([:]).isEmpty)
    }

    // MARK: - fetchModels reduces to plain ids (the AIProviderClient protocol surface)

    func testFetchModelsShapeReducesToIdsOnly() {
        // parseModelDetails is what fetchModels(key:session:) maps over; pin that the id order and
        // values survive the reduction unchanged.
        let ids = client.parseModelDetails(sampleBody).map { $0.id }
        XCTAssertEqual(ids, ["moonshotai/kimi-k3", "google/gemini-3.1-flash-lite-image", "tencent/hy3:free"])
    }

    // MARK: - parseChatContent

    private func chatBody(_ content: String, finishReason: String?) -> [String: Any] {
        var choice: [String: Any] = ["message": ["role": "assistant", "content": content]]
        if let finishReason { choice["finish_reason"] = finishReason }
        return ["choices": [choice]]
    }

    func testChatContentPassesThroughOnNormalCompletion() throws {
        let text = try client.parseChatContent(chatBody("All good.", finishReason: "stop"))
        XCTAssertEqual(text, "All good.")
    }

    func testChatContentAppendsTruncationNoteOnLength() throws {
        let text = try client.parseChatContent(chatBody("cut off mid", finishReason: "length"))
        XCTAssertTrue(text.hasPrefix("cut off mid"))
        XCTAssertTrue(text.contains("Reply cut off"))
        // OpenRouter never fronts a local Ollama-style server, so this note must not carry the
        // context-window-specific local-server advice CustomClient's does.
        XCTAssertFalse(text.lowercased().contains("ollama"))
    }

    func testChatContentMissingMessageIsADecodeError() {
        XCTAssertThrowsError(try client.parseChatContent(["choices": [[:]]]))
    }
}
