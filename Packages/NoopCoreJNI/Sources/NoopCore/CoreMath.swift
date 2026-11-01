import Foundation
import StrandAnalytics
import WhoopProtocol

/// Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`, decision 6): the computations Android's
/// screens used to run as Kotlin copies, answered by the shared Swift code. Each `math.*` operation takes its inputs
/// as JSON and answers JSON; Kotlin keeps its own copy only for a build without the core (the JVM unit tests).
/// Heart-rate series cross as `[[ts, bpm], …]`.
enum CoreMath {
    static func run(_ op: String, _ args: [String: Any]) -> String? {
        switch op {
        case "math.strain":
            let hr = hrSeries(args["hr"])
            let spans = (args["workoutSpans"] as? [[NSNumber]])?.compactMap { pair -> Range<Int>? in
                guard pair.count == 2, pair[0].intValue < pair[1].intValue else { return nil }
                return pair[0].intValue ..< pair[1].intValue
            } ?? []
            let value = StrainScorer.strain(
                hr, maxHR: (args["maxHR"] as? NSNumber)?.doubleValue,
                restingHR: (args["restingHR"] as? NSNumber)?.doubleValue ?? StrainScorer.defaultRestingHR,
                lowIntensity: .countedIn(spans),
                strengthLoad: (args["strengthLoad"] as? NSNumber)?.doubleValue ?? 0)
            return CoreRead.json(["value": value])
        default:
            return nil
        }
    }

    static func hrSeries(_ any: Any?) -> [HRSample] {
        (any as? [[NSNumber]])?.compactMap { pair in
            pair.count >= 2 ? HRSample(ts: pair[0].intValue, bpm: pair[1].intValue) : nil
        } ?? []
    }
}
