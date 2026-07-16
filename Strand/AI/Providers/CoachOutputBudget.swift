import Foundation

/// The output-token ceiling for one coach reply on the OpenAI-shaped providers (OpenAI, Custom, and any
/// gateway fronting them — OpenRouter and friends).
///
/// This is a **ceiling, not a target**. A model stops as soon as it has finished answering, so a larger
/// number does not make an ordinary reply longer, slower, or dearer; it only stops a runaway from
/// costing without bound. A coach answer itself needs roughly 900 tokens.
///
/// It sits far above that for one reason: on a **reasoning model** the internal reasoning is emitted as
/// output tokens, billed at the output rate, and spent *before* the first visible word. At 900 the whole
/// budget could be gone before the answer began. That is not hypothetical — it is how this constant came
/// to exist: Google's Gemini 2.5 Pro (which reasons *mandatorily* — it cannot be turned off) cut off
/// mid-sentence about 40 visible tokens in, having burnt the rest on thinking the user paid for and
/// never saw. Its context window is 1M tokens and it can emit 65k, so our own 900 was the only limit in
/// play. Roughly 200 of OpenRouter's ~340 models reason, so this is the common case, not an edge one.
///
/// Kept in its own file, referenced from the per-provider clients, so the reasoning above lives in one
/// place rather than being re-derived at each of the four call sites.
enum CoachOutputBudget {

    /// Ceiling sent as `max_tokens` / `max_completion_tokens`. Leaves a reasoning model room to think
    /// and still answer, while capping a runaway at a few cents rather than a few dollars.
    static let maxTokens = 4096
}
