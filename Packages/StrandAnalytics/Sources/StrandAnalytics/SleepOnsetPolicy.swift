import WhoopProtocol

extension SleepStager {
    /// Build onset evidence without absorbing active runs or letting a permissive HR median alone turn
    /// a gravity dropout into a qualifying run. Bare gaps remain bridgeable within the existing gap bound
    /// when both the median and mean HR support them. The continuity pass keeps its existing median guard;
    /// this additional check only decides which initial run can establish the onset.
    static func onsetEvidenceRuns(_ periods: [Period], hr: [HRSample], baseline: Double?) -> [Period] {
        var result: [Period] = []
        for period in periods {
            if let last = result.last, last.stage == "sleep", period.stage == "sleep",
               period.start >= last.end, period.start - last.end <= sparseBridgeGapMin * 60,
               let baseline {
                let gapHR = rowsBetween(hr, start: last.end + 1, end: period.start) { $0.ts }
                    .map { Double($0.bpm) }
                if !gapHR.isEmpty {
                    let band = baseline * hrSleepBandMult
                    let mean = gapHR.reduce(0, +) / Double(gapHR.count)
                    if mean <= band && HRVAnalyzer.median(gapHR) <= band {
                        result[result.count - 1] = Period(stage: "sleep", start: last.start, end: period.end)
                        continue
                    }
                }
            }
            result.append(period)
        }
        return result
    }

    /// A bridge may keep an interrupted night together without establishing its onset from a chain of
    /// short leading rest bouts. Once an onset-evidence run clears the ordinary session floor on its own,
    /// leading sub-floor bouts separated from it by observed activity are omitted. This is a conservative
    /// onset policy, not proof that the discarded rest was awake. A qualifying initial run, bare data gaps
    /// and a night with no independently qualifying run keep the existing behavior.
    static func conservativeOnset(for period: Period, evidence: [Period]) -> Int {
        guard period.stage == "sleep",
              let anchor = evidence.first(where: {
                  $0.stage == "sleep" && $0.start >= period.start && $0.end <= period.end
                      && $0.end - $0.start > minSleepMin * 60
              }), anchor.start > period.start else { return period.start }
        let crossedActivity = evidence.contains {
            $0.stage == "active" && $0.start >= period.start && $0.end <= anchor.start
        }
        return crossedActivity ? anchor.start : period.start
    }
}
