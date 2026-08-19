import Foundation

// Quality beside cost, and why a single winner column was the wrong shape.
//
// Every model comparison so far ended in a ranking, and a ranking hides the trade that actually decides the
// question. harrier-oss-v1-0.6b scored best on retrieval while storing four times the index and shipping a
// larger file; EmbeddingGemma scored slightly lower at a quarter of the index. Printed as a league table, the
// first one "wins". Printed side by side, they are two different products and the choice belongs to whoever is
// paying the bytes.
//
// So this section prints the front rather than the winner. A row is DOMINATED when another row is at least as
// good on every axis — quality, index bytes, model bytes, embed time — and strictly better on one. Anything not
// dominated is on the front, and the front is what a decision should be made from.
//
// The axes are deliberately not weighted into a score. A weight is a decision disguised as arithmetic: pick
// bytes-per-point and the ranking follows from the weight, not from the measurement.

struct ParetoRow {
    let model: String
    /// Per-query nDCG on the dev half, kept so models can be compared PAIRED.
    ///
    /// Without this the section would print 0.728 against 0.707 as a ranking, which is the exact mistake the
    /// intervals were introduced to stop. Models answer the same questions, so the difference is paired and far
    /// more resolvable than two independent means would be.
    let perQueryNDCG: [String: Double]
    let dimensions: Int
    /// Whether the dimension count is a trained Matryoshka stage or an untrained truncation. Not a cost, but it
    /// belongs in the same table: an untrained truncation is a different model contract, not a cheaper setting,
    /// and comparing one against a trained stage measures the truncation.
    let matryoshka: Bool
    let ndcg: Double?
    let indexBytes: Int
    let modelFileBytes: Int?
    let embedMilliseconds: Double
    let scoredQueries: Int
}

/// Rows that nothing else beats outright.
///
/// A missing cost is treated as unknown rather than as zero: a row whose model size was never recorded cannot
/// dominate one whose size is known, because "no number" is not the same as "small". Without that rule an old
/// vectors set written before the field existed would sweep the front by having no measurable cost.
func paretoFront(_ rows: [ParetoRow]) -> Set<Int> {
    var front: Set<Int> = []
    for (index, row) in rows.enumerated() {
        guard let quality = row.ndcg else { continue }
        var dominated = false
        for (other, rival) in rows.enumerated() where other != index {
            guard let rivalQuality = rival.ndcg else { continue }
            // Only comparable on a cost axis when both sides have the number.
            let modelBytesComparable = row.modelFileBytes != nil && rival.modelFileBytes != nil
            let atLeastAsGood = rivalQuality >= quality
                && rival.indexBytes <= row.indexBytes
                && rival.embedMilliseconds <= row.embedMilliseconds
                && (!modelBytesComparable || rival.modelFileBytes! <= row.modelFileBytes!)
            let strictlyBetter = rivalQuality > quality
                || rival.indexBytes < row.indexBytes
                || rival.embedMilliseconds < row.embedMilliseconds
                || (modelBytesComparable && rival.modelFileBytes! < row.modelFileBytes!)
            if atLeastAsGood && strictlyBetter { dominated = true; break }
        }
        if !dominated { front.insert(index) }
    }
    return front
}

/// Paired intervals between models, against whichever row is named the incumbent.
///
/// Printed beside the front rather than instead of it: the front answers "what is not beaten outright", and this
/// answers "is the quality difference real at all". A model that wins the quality column by less than its
/// interval has not won it.
func printModelComparisons(_ rows: [ParetoRow], incumbent: String) {
    guard let baseline = rows.first(where: { $0.model == incumbent }) else { return }
    print("""

          vs `\(incumbent)` — paired bootstrap over the same dev queries, 95% CI
        -----------------------------------------------------------------------------------------------
        """)
    for row in rows where row.model != incumbent {
        guard let interval = pairedBootstrap(baseline: baseline.perQueryNDCG,
                                            candidate: row.perQueryNDCG) else { continue }
        let verdict = interval.isInconclusive
            ? "~ indistinguishable"
            : (interval.delta > 0 ? "+ better" : "- worse")
        // Padded explicitly: `%-38@` does not pad an NSString, which ran the model name into the delta the
        // first time this printed — the second time that same mistake was made in this file.
        let name = row.model.count >= 40
            ? String(row.model.prefix(40))
            : row.model + String(repeating: " ", count: 40 - row.model.count)
        print(String(format: "  %@ %+.3f   [%+.3f, %+.3f]  n=%d  %@",
                     name as NSString,
                     interval.delta, interval.low, interval.high, interval.n,
                     verdict as NSString))
    }
    print("")
}

func printPareto(_ rows: [ParetoRow]) {
    let front = paretoFront(rows)
    print("""

        ================================================================================
        PARETO VIEW — quality against what it costs
        ================================================================================
        nDCG@8 is the DEVELOPMENT half of `main` only, which is the only scope a model may be
        chosen on. Index bytes are the app's own Float16 encoding at the stored dimension, so a
        model that wins by storing four times as much shows it here rather than in a footnote.

        `trained` says whether the stored dimension is a documented Matryoshka stage or an
        untrained truncation. That is not a cost — it is a different contract, and comparing an
        untrained truncation against a trained stage measures the truncation and not the model.

        No axis is weighted into a single score. A weight is a decision disguised as
        arithmetic: choose bytes-per-point and the ranking follows from the choice.

        ★ = on the Pareto front (nothing beats it outright)

          model                                dim  trained    nDCG@8   index KB   model MB   embed s     n
        -----------------------------------------------------------------------------------------------
        """)
    // Padded in Swift rather than through format specifiers: `%-7@` does not pad an NSString, so the columns
    // silently ran together the first time this printed.
    func column(_ text: String, _ width: Int, alignRight: Bool = false) -> String {
        if text.count >= width { return String(text.prefix(width)) }
        let padding = String(repeating: " ", count: width - text.count)
        return alignRight ? padding + text : text + padding
    }
    for (index, row) in rows.enumerated() {
        let quality = row.ndcg.map { String(format: "%.3f", $0) } ?? "  —"
        let modelSize = row.modelFileBytes.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "?"
        print("  " + (front.contains(index) ? "★ " : "  ")
            + column(row.model, 34)
            + column("\(row.dimensions)", 5, alignRight: true) + "  "
            + column(row.matryoshka ? "yes" : "NO", 8)
            + column(quality, 7, alignRight: true) + "   "
            + column("\(row.indexBytes / 1024)", 8, alignRight: true) + "   "
            + column(modelSize, 8, alignRight: true) + "   "
            + column(String(format: "%.1f", row.embedMilliseconds / 1000), 7, alignRight: true) + "  "
            + column("\(row.scoredQueries)", 4, alignRight: true))
    }
    if rows.count > 1, front.count == rows.count {
        print("\n  Every row is on the front, which means no candidate is beaten outright on all axes —")
        print("  the choice is a trade, not a ranking.")
    }
    print("")
}
