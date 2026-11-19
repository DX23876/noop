import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The measures Today's tile gallery offers, in its order, and the source each one is READ from.
///
/// One table, because a tile's history must not be fetched from different places on the two phones. Until
/// 2026-11-19 the iPhone carried this list with its sources in `ForgeWidgetMeasures` while Android asked for
/// every measure under the strap's source, so its weight tile read an empty series and its two-column form
/// silently fell back to the usual-and-range line: "Weighed today · ±0,0 kg this week" on one phone and no
/// line at all on the other, from the same data.
///
/// Pure data. Analysis migration required: no.
enum TileMeasures {

    /// The catalogue's own groups, which the gallery now shows as sections (owner, 2026-11-18). A list of
    /// twenty-odd measures in one run is a list nobody reads to the end.
    enum Section: String, CaseIterable, Sendable {
        case charge, rest, effort, heart, body, food, mind
    }

    /// Catalogue key, preferred source and the section it is offered under, in the gallery's order.
    ///
    /// Charge, Effort and Rest lead their own sections and are only ever drawn across the whole row, since
    /// the three rings above already say today's number.
    static let all: [(key: String, source: String, section: Section)] = [
        ("recovery", MetricResolver.whoopSource, .charge),

        ("sleep_performance", MetricResolver.whoopSource, .rest),
        ("sleep_total_min", MetricResolver.whoopSource, .rest),
        ("sleep_debt_min", MetricResolver.whoopSource, .rest),

        ("strain", MetricResolver.whoopSource, .effort),
        ("steps", MetricResolver.whoopSource, .effort),
        ("active_kcal", MetricResolver.appleHealthSource, .effort),
        ("hr_zones13_min", MetricResolver.whoopSource, .effort),
        ("hr_zones45_min", MetricResolver.whoopSource, .effort),

        ("hrv", MetricResolver.whoopSource, .heart),
        ("rhr", MetricResolver.whoopSource, .heart),
        ("spo2", MetricResolver.whoopSource, .heart),
        ("resp_rate", MetricResolver.whoopSource, .heart),
        ("vo2max_est", MetricResolver.whoopSource, .heart),
        ("stress", MetricResolver.whoopSource, .heart),

        ("weight", "noop-weight", .body),
        ("body_fat", MetricResolver.appleHealthSource, .body),
        ("lean_mass", MetricResolver.appleHealthSource, .body),
        ("skin_temp", MetricResolver.whoopSource, .body),
        ("fitness_age", MetricResolver.whoopSource, .body),
        ("vitality", MetricResolver.whoopSource, .body),
        ("body_age", MetricResolver.whoopSource, .body),

        ("calories_in", "nutrition-csv", .food),
        // The one macro with a goal of its own in the core, so the only one worth a tile beside the
        // Nutrition card (owner, 2026-11-18).
        ("protein_g", "nutrition-csv", .food),

        ("mood", "noop-mood", .mind),
    ]

    /// The keys alone, in the same order.
    static var keys: [String] { all.map(\.key) }

    /// The source a key is read from, the strap's for anything the gallery does not name.
    static func source(forKey key: String) -> String {
        all.first { $0.key == key }?.source ?? MetricResolver.whoopSource
    }

    /// How far back a tile reads, decided here so both phones hold the same history in their hands.
    ///
    /// Sixty days covers the thirty a tile draws plus the thirty its change chip is read against. Four
    /// measures need a year instead: VO2max, the fitness age and the two body ages move too slowly for a
    /// month to show anything, and their own row-wide form is a year (owner, 2026-11-19). Reading them over
    /// sixty days was why their wider forms could say nothing about a change at all.
    static func windowDays(forKey key: String) -> Int {
        ["vo2max_est", "fitness_age", "vitality", "body_age"].contains(key) ? 365 : 60
    }
}

/// One measure's history as a Today tile reads it: the days it has, oldest first, and the scale they are on
/// where that is a question.
struct TileHistory: Sendable {
    let days: [String]
    let values: [Double]
    /// Which of skin temperature's two scales these values are on, nil for every other measure.
    let skinKind: SkinTempDisplay.Kind?

    init(days: [String], values: [Double], skinKind: SkinTempDisplay.Kind? = nil) {
        self.days = days; self.values = values; self.skinKind = skinKind
    }

    var points: [MeasureFacts.Point] {
        zip(days, values).map { MeasureFacts.Point(day: $0, value: $1) }
    }

    static let none = TileHistory(days: [], values: [])
}

extension StoreReader {

    /// Read a tile's history for `key`, by the route that measure needs.
    ///
    /// Three measures do not come from the plain Explore read, and each is a case where reading the stored
    /// column instead prints a plausible figure that is not the one the rest of the app shows:
    ///
    /// - **Steps** go through the app's one step resolver and the source the wearer chose (`StepsSource`),
    ///   the same read the steps page, the rolling tile and AgeLess use. The stored `steps` column alone is
    ///   the strap's count, so a phone-steps wearer would see a different total on Today than on the steps
    ///   page.
    /// - **Skin temperature** is bimodal: one column holds a wrist temperature from an import and a
    ///   baseline move from the computed pipeline (#1705), so the pair is read per night and reduced to the
    ///   newest night's scale. Averaging across the two is arithmetic on two scales and looks entirely
    ///   plausible.
    /// - Everything else takes its gallery source, then any other catalogue source of the same measure that
    ///   has days, which is how a measure only an import carries still fills its tile.
    func tileHistory(key: String, from: String, to: String, dailyRows: [DailyMetric],
                     suppressedSleepWakeDays: Set<String>,
                     skinTempPrefer: SkinTempDisplay.Kind = .absolute) async -> TileHistory {
        if key == "steps" {
            let points = await MetricResolver.resolvedSteps(store: store, actualWhoopSource: activeDeviceId,
                                                            from: from, to: to).points
            return TileHistory(days: points.map(\.day), values: points.map(\.value))
        }
        if key == "skin_temp" {
            let readings = dailyRows
                .filter { $0.day >= from && $0.day <= to }
                .sorted { $0.day < $1.day }
                .compactMap { row -> (day: String, reading: SkinTempDisplay.Reading)? in
                    SkinTempDisplay.leadReading(absC: row.skinTempC, devC: row.skinTempDevC,
                                                prefer: skinTempPrefer).map { (row.day, $0) }
                }
            // The newest night decides the scale and the older nights on the other one are dropped rather
            // than mixed in: the kind is KNOWN here instead of guessed from how large the number looks.
            guard let kind = readings.last?.reading.kind else { return .none }
            let kept = readings.filter { $0.reading.kind == kind }
            return TileHistory(days: kept.map(\.day), values: kept.map(\.reading.value), skinKind: kind)
        }
        var sources = [TileMeasures.source(forKey: key)]
        sources += MetricCatalog.all.filter { $0.key == key && !sources.contains($0.source) }.map { $0.source }
        for source in sources {
            let series = await exploreSeries(key: key, source: source, from: from, to: to,
                                            dailyRows: dailyRows,
                                            suppressedSleepWakeDays: suppressedSleepWakeDays)
            if !series.isEmpty {
                return TileHistory(days: series.map { $0.day }, values: series.map { $0.value })
            }
        }
        return .none
    }
}
