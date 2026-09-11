import Foundation
import SwiftUI
import StrandAnalytics
import StrandImport
import WhoopStore

// MARK: - What the Body screen knows
//
// The same split as the Strength and Cardio screens: the derivations are pure and live in
// `Packages/StrandAnalytics` (`BodyMetrics`, `NavyBodyFat`), and the orchestration — which window,
// what is being captured, what the tape guidance says — lives here rather than in a SwiftUI body.
//
// One thing this model deliberately does NOT do is compute a body-fat number and then quietly show it
// beside a measured one. A Navy estimate and a DEXA result are different measurements; they are kept
// on separate series and labelled, because averaging them would produce a figure that nobody measured.

@MainActor
final class BodyModel: ObservableObject {

    enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
        case quarter, year, all
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .quarter: return 120
            case .year:    return 365
            case .all:     return 4_000
            }
        }
        var label: String {
            switch self {
            case .quarter: return String(localized: "3 months")
            case .year:    return String(localized: "1 year")
            case .all:     return String(localized: "All")
            }
        }
    }

    @Published private(set) var metrics = BodyMetrics.empty
    @Published private(set) var loaded = false
    @Published var range: HistoryRange = .quarter

    /// Today's key, resolved once per load so every readout on the screen answers the same day.
    @Published private(set) var today = Repository.localDayKey(Date())

    func load(repo: Repository) async {
        today = Repository.localDayKey(Date())
        metrics = await repo.bodyMetrics(days: range.days)
        ensureSelectedSite()
        loaded = true
    }

    // MARK: - Readouts

    /// The reading in force today for `key`.
    func current(_ key: String) -> BodyReading? { metrics.asOf(key, day: today) }

    /// Every circumference site that has ever been measured, in the catalog's head-to-toe order.
    var measuredSites: [String] {
        MarkerCatalog.circumferenceKeys.filter { !metrics.series($0).isEmpty }
    }

    /// Sites with no reading yet — what the capture sheet offers to start tracking.
    var unmeasuredSites: [String] {
        MarkerCatalog.circumferenceKeys.filter { metrics.series($0).isEmpty }
    }

    // MARK: - Development over time
    //
    // The comparison people actually make with a tape: this site now against this site a few weeks ago.
    // Growing on a bulk, shrinking on a cut — which is also why neither direction is coloured as good.

    enum ComparisonWindow: Int, CaseIterable, Identifiable, Sendable {
        case threeWeeks = 21
        case sixWeeks = 42
        case threeMonths = 90

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .threeWeeks:  return String(localized: "3 weeks")
            case .sixWeeks:    return String(localized: "6 weeks")
            case .threeMonths: return String(localized: "3 months")
            }
        }
    }

    @Published var comparison: ComparisonWindow = .sixWeeks

    /// The day the comparison reaches back to.
    var comparisonFromDay: String {
        let date = Calendar.current.date(byAdding: .day, value: -comparison.rawValue, to: Date())
            ?? Date()
        return Repository.localDayKey(date)
    }

    /// Every site with a usable comparison, largest movement first — what moved most is what the
    /// wearer wants to see first, and head-to-toe order buries it.
    var circumferenceChanges: [CircumferenceChange] {
        MarkerCatalog.circumferenceKeys.compactMap { key in
            CircumferenceProgress.change(key: key, readings: metrics.series(key),
                                         from: comparisonFromDay, to: today)
        }
        .sorted { abs($0.deltaCm) > abs($1.deltaCm) }
    }

    /// Direction counts and internal magnitudes after each site's own scatter is removed.
    var circumferenceTotal: CircumferenceTotal {
        CircumferenceProgress.total(circumferenceChanges)
    }

    /// Weight over the same window, so the tape can be read against the scale — the whole point when
    /// the scale has stalled.
    var weightChangeKg: Double? {
        let key = WhoopStore.bodyWeightMetricKey
        guard let then = metrics.value(key, on: comparisonFromDay),
              let now = metrics.value(key, on: today), then > 0 else { return nil }
        return now - then
    }

    /// The Navy estimate for today's measurements, or nil when the tape readings it needs are absent.
    func navyEstimate(equation: NavyEquation) -> Double? {
        guard let height = current("height")?.value,
              let neck = current("neck")?.value,
              let waist = current("waist")?.value else { return nil }
        return NavyBodyFat.percent(equation: equation, heightCm: height, neckCm: neck,
                                   waistCm: waist, hipCm: current("hips")?.value)
    }

    /// What the Navy estimate is still missing, so the screen can ask for it by name rather than
    /// showing an unexplained blank.
    func navyMissingSites(equation: NavyEquation) -> [String] {
        var missing: [String] = []
        if current("height") == nil { missing.append("height") }
        if current("neck") == nil { missing.append("neck") }
        if current("waist") == nil { missing.append("waist") }
        if equation.needsHip, current("hips") == nil { missing.append("hips") }
        return missing
    }

    /// Body-fat readings split by where they came from. DEXA and a tape estimate are not the same
    /// measurement and must not sit on one line.
    var bodyFatBySource: [(source: String, points: [BodyReading])] {
        Dictionary(grouping: metrics.series("body_fat"), by: \.source)
            .map { (source: $0.key, points: $0.value) }
            .sorted { $0.source < $1.source }
    }

    // MARK: - One site's history

    /// Which circumference the history card is showing. Defaults to the first site that has enough
    /// points to draw, so the card opens on something rather than on a picker and an empty frame.
    @Published var selectedSite: String?

    /// Re-picks the shown site when the current one has nothing to draw in this window.
    func ensureSelectedSite() {
        let plottable = MarkerCatalog.circumferenceKeys.filter { metrics.series($0).count >= 2 }
        if let selectedSite, plottable.contains(selectedSite) { return }
        selectedSite = plottable.first
    }

    /// Sites with at least two readings — the ones a trend can honestly be drawn for.
    var plottableSites: [String] {
        MarkerCatalog.circumferenceKeys.filter { metrics.series($0).count >= 2 }
    }

    /// The change in the selected site across the window, in centimetres.
    func siteChange(_ key: String) -> Double? {
        let series = metrics.series(key)
        guard let first = series.first, let last = series.last, series.count >= 2 else { return nil }
        return last.value - first.value
    }

    // MARK: - Labels

    /// Localized UI label for a locale-stable stored marker key.
    func label(_ key: String) -> String {
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
    ///
    /// Circumference data is almost entirely method noise when the method varies — a tape held at a
    /// different height or tension moves the number more than a month of training does. Without this
    /// the chart is a random walk drawn beautifully.
    func guidance(_ key: String) -> String? {
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
}
