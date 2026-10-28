import Foundation
import StrandAnalytics
import StrandCore
import StrandImport
import WhoopStore

// BodyPreparation.swift — fork feature "Body": what the Body screen reads from the measurements, shared by the
// Apple app (`BodyModel`) and the Android core (parity plan 2.3). The derivations live in StrandAnalytics
// (`BodyMetrics`, `NavyBodyFat`, `CircumferenceProgress`); this is the orchestration and the wording.

enum BodyPreparation {
    /// Every circumference site that has ever been measured, in the catalog's head-to-toe order.
    static func measuredSites(_ metrics: BodyMetrics) -> [String] {
        MarkerCatalog.circumferenceKeys.filter { !metrics.series($0).isEmpty }
    }

    /// Sites with no reading yet — what the capture sheet offers to start tracking.
    static func unmeasuredSites(_ metrics: BodyMetrics) -> [String] {
        MarkerCatalog.circumferenceKeys.filter { metrics.series($0).isEmpty }
    }

    /// Every site with a usable comparison, largest movement first.
    static func circumferenceChanges(_ metrics: BodyMetrics, from: String, to: String) -> [CircumferenceChange] {
        MarkerCatalog.circumferenceKeys.compactMap { key in
            CircumferenceProgress.change(key: key, readings: metrics.series(key), from: from, to: to)
        }
        .sorted { abs($0.deltaCm) > abs($1.deltaCm) }
    }

    /// Weight over the same window, so the tape can be read against the scale.
    static func weightChangeKg(_ metrics: BodyMetrics, from: String, to: String) -> Double? {
        let key = WhoopStore.bodyWeightMetricKey
        guard let then = metrics.value(key, on: from), let now = metrics.value(key, on: to), then > 0 else { return nil }
        return now - then
    }

    /// The Navy estimate for the day's measurements, or nil when the tape readings it needs are absent.
    static func navyEstimate(_ metrics: BodyMetrics, today: String, equation: NavyEquation) -> Double? {
        guard let height = metrics.asOf("height", day: today)?.value,
              let neck = metrics.asOf("neck", day: today)?.value,
              let waist = metrics.asOf("waist", day: today)?.value else { return nil }
        return NavyBodyFat.percent(equation: equation, heightCm: height, neckCm: neck,
                                   waistCm: waist, hipCm: metrics.asOf("hips", day: today)?.value)
    }

    /// What the Navy estimate is still missing, so the screen can ask for it by name.
    static func navyMissingSites(_ metrics: BodyMetrics, today: String, equation: NavyEquation) -> [String] {
        var missing: [String] = []
        if metrics.asOf("height", day: today) == nil { missing.append("height") }
        if metrics.asOf("neck", day: today) == nil { missing.append("neck") }
        if metrics.asOf("waist", day: today) == nil { missing.append("waist") }
        if equation.needsHip, metrics.asOf("hips", day: today) == nil { missing.append("hips") }
        return missing
    }

    /// Sites with at least two readings — the ones a trend can honestly be drawn for.
    static func plottableSites(_ metrics: BodyMetrics) -> [String] {
        MarkerCatalog.circumferenceKeys.filter { metrics.series($0).count >= 2 }
    }

    /// The change in one site across the loaded window, in centimetres.
    static func siteChange(_ metrics: BodyMetrics, _ key: String) -> Double? {
        let series = metrics.series(key)
        guard let first = series.first, let last = series.last, series.count >= 2 else { return nil }
        return last.value - first.value
    }

    /// Localized UI label for a locale-stable stored marker key.
    static func label(_ key: String) -> String {
        switch key {
        case "weight":    return String(localized: "Weight")
        case "body_fat":  return String(localized: "Body fat")
        case "waist":     return String(localized: "Waist circumference")
        case "height":    return String(localized: "Height")
        case "neck":      return String(localized: "Neck")
        case "shoulders": return String(localized: "Shoulders")
        case "chest":     return String(localized: "Chest")
        case "abdomen":   return String(localized: "Abdomen")
        case "hips":      return String(localized: "Hips")
        case "thigh_l":   return String(localized: "Thigh (left)")
        case "thigh_r":   return String(localized: "Thigh (right)")
        case "calf_l":    return String(localized: "Calf (left)")
        case "calf_r":    return String(localized: "Calf (right)")
        case "biceps_l":  return String(localized: "Biceps (left)")
        case "biceps_r":  return String(localized: "Biceps (right)")
        case "forearm_l": return String(localized: "Forearm (left)")
        case "forearm_r": return String(localized: "Forearm (right)")
        default:           return MarkerCatalog.definition(for: key)?.displayName ?? key
        }
    }

    /// How to take this measurement, shown where it is entered.
    static func guidance(_ key: String) -> String? {
        switch key {
        case "neck":
            return String(localized: "Just below the larynx, tape sloping slightly down at the front. Do not flex.")
        case "shoulders":
            return String(localized: "Around the widest point of the deltoids, arms relaxed at your sides.")
        case "chest":
            return String(localized: "At nipple height, at the end of a normal breath out.")
        case "waist":
            return String(localized: "At the navel, standing relaxed. Do not pull the stomach in — the same posture every time matters more than the posture you pick.")
        case "abdomen":
            return String(localized: "At the navel, relaxed. Hevy tracks this separately from the waist — the waist is the narrowest point, the abdomen is at the navel.")
        case "hips":
            return String(localized: "Around the widest point of the buttocks, feet together.")
        case "biceps_l", "biceps_r":
            return String(localized: "Midway between shoulder and elbow. Relaxed or flexed both work — record the same one every time.")
        case "forearm_l", "forearm_r":
            return String(localized: "At the widest point below the elbow, arm hanging relaxed.")
        case "thigh_l", "thigh_r":
            return String(localized: "Midway between hip crease and knee, weight evenly on both feet.")
        case "calf_l", "calf_r":
            return String(localized: "At the widest point, standing with weight evenly on both feet.")
        default:
            return nil
        }
    }

    /// The stored rows for one measurement session: one instant, n values, one optional note.
    static func measurementRows(_ values: [String: Double], deviceId: String, takenAt: Date, source: String,
                                note: String?) -> [LabMarkerRow] {
        let epoch = Int(takenAt.timeIntervalSince1970)
        let day = StoreReader.localDayKey(takenAt)
        return values.compactMap { key, value -> LabMarkerRow? in
            guard value.isFinite, value > 0 else { return nil }
            let definition = MarkerCatalog.definition(for: key)
            return LabMarkerRow(
                id: "\(key)-\(epoch)-\(UUID().uuidString.prefix(8))",
                deviceId: deviceId, markerKey: key,
                category: (definition?.category ?? .bodyMeasurement).rawValue,
                day: day, takenAt: epoch, value: value, valueText: nil,
                unit: definition?.canonicalUnit ?? "cm",
                source: source, note: note, referenceText: nil)
        }
    }
}
