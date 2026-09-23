import Foundation

/// Every analysis the Coach runs while composing ONE answer. It is the ledger behind the multiple-testing
/// rule: a model that runs five comparisons and reports the one that came out "significant" has found noise
/// one time in four at p < 0.05. Each result therefore carries its q-value adjusted over every test run so
/// far in the answer (Benjamini–Hochberg), and says how many there were.
///
/// Create one per answer and discard it afterwards; it is not thread-safe and does not need to be.
public final class AnalysisSession {

    /// One executed call, kept for the "How this was calculated" card.
    public struct Run: Equatable, Sendable {
        public let spec: AnalysisSpec
        public let result: AnalysisResult
        /// Indices of this run's tests in the session-wide test list.
        public let testIndices: [Int]
    }

    public private(set) var runs: [Run] = []
    public private(set) var tests: [AnalysisTest] = []
    public let dataset: AnalysisDataset
    private let executor: AnalysisExecutor

    public init(dataset: AnalysisDataset) {
        self.dataset = dataset
        self.executor = AnalysisExecutor(data: dataset)
    }

    /// q-values over every test in the session so far, in test order.
    public var qValues: [Double] { AnalysisStatistics.benjaminiHochberg(tests.map(\.p)) }

    /// Handles one `run_analysis` tool call: `{ "plan": "...", "spec": { ... } }`. Returns the text for the
    /// model — the result, or the issues to fix. Never throws: a bad call is an answer the model can use.
    public func handleToolCall(_ input: [String: Any]) -> String {
        let plan = (input["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !plan.isEmpty else {
            return Self.issueText([.init(field: "plan", message: "is required: one sentence saying what you will compute and why")])
        }
        guard let rawSpec = input["spec"] else {
            return Self.issueText([.init(field: "spec", message: "is required")])
        }
        switch AnalysisSpec.decode(toolInput: rawSpec) {
        case .failure(let issue):
            return Self.issueText([issue])
        case .success(let spec):
            return run(spec, plan: plan)
        }
    }

    /// Validates and runs a spec, recording its tests. Returns the rendered text for the model.
    public func run(_ spec: AnalysisSpec, plan: String) -> String {
        let issues = AnalysisValidator.validate(spec, against: dataset)
        guard issues.isEmpty else { return Self.issueText(issues) }
        let result = executor.run(spec, plan: plan)
        let start = tests.count
        tests += result.tests
        let run = Run(spec: spec, result: result, testIndices: Array(start..<tests.count))
        runs.append(run)
        return render(run)
    }

    // MARK: - Rendering

    static func issueText(_ issues: [AnalysisIssue]) -> String {
        (["ANALYSIS NOT RUN — fix the spec and call run_analysis again:"] + issues.map { "  • \($0)" })
            .joined(separator: "\n")
    }

    func render(_ run: Run) -> String {
        let r = run.result
        var lines = [
            "ANALYSIS #\(runs.count) — \(r.operation.rawValue), \(r.windowFrom) → \(r.windowTo)",
            "Plan: \(r.plan)",
            "Measure: \(r.metricLabel)" + (r.unit.map { " [\($0)]" } ?? ""),
        ]
        lines += r.facts
        let q = qValues
        for (offset, test) in run.result.tests.enumerated() {
            let index = run.testIndices[offset]
            let unit = test.inMetricUnit ? r.unit : nil
            let estimate = test.inMetricUnit ? AnalysisFormat.signed(test.estimate) : String(format: "%.2f", test.estimate)
            let bounds = test.inMetricUnit
                ? "\(AnalysisFormat.signed(test.lower)) to \(AnalysisFormat.signed(test.upper))"
                : String(format: "%.2f to %.2f", test.lower, test.upper)
            var line = "Test T\(index + 1): \(test.label) = " + AnalysisFormat.withUnit(estimate, unit)
                + " (95% CI \(bounds); \(AnalysisFormat.p(test.p)); \(AnalysisFormat.p(q[index], name: "q")); n = \(test.n))"
            if let g = test.effectSize { line += "; effect size g = " + String(format: "%.2f", g) }
            lines.append(line)
            lines.append("  → " + Self.verdict(test, q: q[index], testCount: tests.count, operation: r.operation))
        }
        if !r.confounders.isEmpty {
            lines.append("Possible confounders (the compared days also differed in):")
            lines += r.confounders.map { "  • \($0)" }
        }
        if !r.notes.isEmpty { lines += r.notes.map { "Note: \($0)" } }
        lines.append("Analyses in this answer so far: \(runs.count), statistical tests: \(tests.count). "
                     + "Tell the wearer how many you ran, and judge each test by its q, which is corrected for all of them.")
        if tests.count > run.result.tests.count {
            let all = q.enumerated().map { "T\($0.offset + 1) \(AnalysisFormat.p($0.element, name: "q"))" }
            lines.append("Updated q for every test in this answer: " + all.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Words, not stars. "No reliable difference" is never "no difference": absence of evidence over a few
    /// dozen days is not evidence of absence.
    static func verdict(_ test: AnalysisTest, q: Double, testCount: Int, operation: AnalysisSpec.Operation) -> String {
        let subject: String
        switch operation {
        case .trend: subject = "trend"
        case .correlate: subject = "association"
        default: subject = "difference"
        }
        if q < 0.05 { return "reliable \(subject) (survives correction for \(testCount) test(s))" }
        if test.p < 0.05 {
            return "suggestive only: p < 0.05 but it does not survive correction for the \(testCount) tests in this answer"
        }
        return "no reliable \(subject) in this data (which is not proof that there is none)"
    }
}
