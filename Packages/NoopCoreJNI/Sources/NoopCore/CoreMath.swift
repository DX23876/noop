import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

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
        case "math.boutCalories":
            let (active, total) = Calories.estimateBoutCalories(
                hrSeries(args["hr"]), profile: profile(args["profile"]),
                hrmax: (args["hrmax"] as? NSNumber)?.doubleValue,
                restingHR: (args["restingHR"] as? NSNumber)?.doubleValue)
            return CoreRead.json(["active": active, "total": total])
        case "math.readiness":
            let r = ReadinessEngine.evaluate(days: decode([DailyMetric].self, args["days"]) ?? [],
                                             today: args["today"] as? String)
            struct Sig: Encodable { let key, label, detail, flag: String; let evidence: String? }
            struct Wire: Encodable {
                let level, headline, summary: String; let signals: [Sig]; let monotony: Double?; let confidence: String
            }
            return CoreRead.json(Wire(
                level: r.level.rawValue, headline: r.headline, summary: r.summary,
                signals: r.signals.map { Sig(key: $0.key, label: $0.label, detail: $0.detail, flag: $0.flag.rawValue,
                                             evidence: $0.evidence) },
                monotony: r.monotony, confidence: String(describing: r.confidence)))
        default:
            return nil
        }
    }

    /// A JSON value from Android decoded through the Swift type's own `Codable` shape.
    static func decode<T: Decodable>(_ type: T.Type, _ any: Any?) -> T? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The wearer's profile as Android's `UserProfile` carries it.
    static func profile(_ any: Any?) -> UserProfile {
        let p = any as? [String: Any] ?? [:]
        func d(_ k: String, _ fallback: Double) -> Double { (p[k] as? NSNumber)?.doubleValue ?? fallback }
        return UserProfile(weightKg: d("weightKg", 70), heightCm: d("heightCm", 170), age: d("age", 30),
                           sex: p["sex"] as? String ?? "nonbinary", stepTicksPerStep: d("stepTicksPerStep", 1),
                           maxHR: (p["maxHR"] as? NSNumber)?.doubleValue)
    }

    static func hrSeries(_ any: Any?) -> [HRSample] {
        (any as? [[NSNumber]])?.compactMap { pair in
            pair.count >= 2 ? HRSample(ts: pair[0].intValue, bpm: pair[1].intValue) : nil
        } ?? []
    }
}
