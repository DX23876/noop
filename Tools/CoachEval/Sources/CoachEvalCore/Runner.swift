import Foundation
import CoachAnalysis

/// One scored question.
public struct EvalRecord: Codable, Sendable {
    public var id: String
    public var template: String
    public var wearer: Int
    public var provider: String
    public var model: String
    public var language: String
    public var question: String
    public var expected: Expected
    public var correct: Bool
    public var transcript: Transcript
    public var seconds: Double
    public var error: String?
}

public enum Runner {

    /// The Coach's instructions for the evaluation. Only what the analysis needs: the date to resolve
    /// "last 30 days" against, the language, and that numbers come from the tool.
    public static func systemPrompt(today: String, language: String) -> String {
        let languageName = language == "de" ? "German" : "English"
        return """
            You are the wearer's health coach inside the NOOP app. Today is \(today). Answer in \(languageName).
            For any number from the wearer's own history, call run_analysis and report what it returns; never \
            estimate or compute a figure yourself. Answer in two to four sentences: the number with its unit, \
            what it means, and how sure the analysis is.
            """
    }

    /// Runs every question's reference spec through the executor and scores the rendered result. Every
    /// question must pass: a failure means the reference and the executor disagree about what a question
    /// means, or the question cannot be answered with the spec language.
    public static func oracle(_ questions: [EvalQuestion], cohort: [SyntheticWearer]) -> [(EvalQuestion, String, Bool)] {
        questions.map { question in
            let session = AnalysisSession(dataset: cohort[question.wearer].dataset)
            // Scored without the header line (analysis number, operation, window bounds): a model's answer
            // does not repeat it, and its dates are not part of any answer.
            let text = session.run(question.oracleSpec, plan: question.oraclePlan)
                .split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            return (question, text, Scorer.isCorrect(text, question.expected))
        }
    }

    public static func run(_ questions: [EvalQuestion], cohort: [SyntheticWearer], provider: EvalProvider,
                           language: String, progress: (EvalRecord) -> Void) async -> [EvalRecord] {
        var records: [EvalRecord] = []
        for question in questions {
            let dataset = cohort[question.wearer].dataset
            let session = AnalysisSession(dataset: dataset)
            let start = Date()
            var record = EvalRecord(id: question.id, template: question.template, wearer: question.wearer,
                                    provider: provider.name, model: provider.model, language: language,
                                    question: question.text(language), expected: question.expected,
                                    correct: false, transcript: Transcript(), seconds: 0, error: nil)
            do {
                record.transcript = try await provider.run(
                    system: systemPrompt(today: dataset.today, language: language),
                    question: question.text(language), dataset: dataset,
                    handle: { session.handleToolCall($0) })
                record.correct = Scorer.isCorrect(record.transcript.answer, question.expected)
            } catch {
                record.error = String(describing: error)
            }
            record.seconds = Date().timeIntervalSince(start)
            records.append(record)
            progress(record)
        }
        return records
    }

    /// A markdown summary: accuracy against the pre-registered bar, tokens, and how often the model had to
    /// repair a refused spec.
    public static func report(_ records: [EvalRecord]) -> String {
        guard !records.isEmpty else { return "No records." }
        var lines: [String] = []
        let groups = Dictionary(grouping: records) { "\($0.provider) · \($0.model) · \($0.language)" }
        for (key, rows) in groups.sorted(by: { $0.key < $1.key }) {
            let answered = rows.filter { $0.error == nil }
            let correct = rows.filter(\.correct).count
            let accuracy = Double(correct) / Double(rows.count)
            let tokens = answered.map { $0.transcript.inputTokens + $0.transcript.outputTokens }.sorted()
            let median = tokens.isEmpty ? 0 : tokens[tokens.count / 2]
            let withInvalid = answered.filter { $0.transcript.invalidCalls > 0 }
            let repaired = withInvalid.filter(\.correct).count
            let noTool = answered.filter { $0.transcript.toolCalls == 0 }.count
            lines.append("## \(key)")
            lines.append("")
            lines.append("- Objective accuracy: **\(correct)/\(rows.count) = \(String(format: "%.1f", accuracy * 100)) %** "
                         + "(bar: ≥ 90 %) — \(accuracy >= 0.9 ? "passes" : "does not pass")")
            lines.append("- Errors (no answer): \(rows.count - answered.count)")
            lines.append("- Median tokens per question: \(median)")
            lines.append("- Answered without calling the tool: \(noTool)")
            lines.append("- Questions with a refused spec: \(withInvalid.count), of which answered correctly after repair: \(repaired)")
            lines.append("")
            lines.append("| Template | Correct |")
            lines.append("|---|---|")
            let byTemplate = Dictionary(grouping: rows) { $0.template.split(separator: "-").prefix(1).joined() }
            for (template, subset) in byTemplate.sorted(by: { $0.key < $1.key }) {
                lines.append("| \(template) | \(subset.filter(\.correct).count)/\(subset.count) |")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
