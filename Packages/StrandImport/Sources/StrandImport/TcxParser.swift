import Foundation
#if canImport(FoundationXML)
// corelibs Foundation moved the event-driven XML parser into its own module; Darwin keeps it in
// Foundation. Conditional so one import serves both, with no #if at the use sites.
import FoundationXML
#endif

// MARK: - TCX parser (Garmin Training Center XML)
//
// TrainingCenterDatabase > Activities > Activity (Sport="Running") > Lap > Track > Trackpoint:
//   <Time>, <Position><LatitudeDegrees/><LongitudeDegrees/></Position>, <AltitudeMeters>,
//   <DistanceMeters> (cumulative), <HeartRateBpm><Value/></HeartRateBpm>, <Cadence>.
// Each <Lap> also carries summary <TotalTimeSeconds>, <DistanceMeters>, <Calories>,
// <AverageHeartRateBpm><Value/>, <MaximumHeartRateBpm><Value/>. We sum the per-lap summaries
// (Calories, DistanceMeters) so the workout's energy/distance come from the file's own figures when
// present, and fall back to the track otherwise.
//
// Conceptually adapted from the structure of FitnessKit/TcxDataProtocol (MIT); NOOP's own clean
// implementation on Foundation `XMLParser`, with the same XXE / entity-expansion / count guards as the
// GPX parser.

enum TcxParser {

    static func parse(data: Data) -> ActivityFileImportResult {
        let delegate = TcxDelegate()
        let parser = XMLParser(data: BOM.stripUTF8(data))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        let ok = parser.parse()
        _ = ok
        if delegate.aborted {
            return ActivityFileImportResult(activity: nil, kind: .tcx, skipped: delegate.skipped)
        }

        // TCX's per-trackpoint DistanceMeters is CUMULATIVE; the most reliable total is the last
        // trackpoint's value or the summed lap distances — prefer summed lap distances, then the
        // cumulative track max, then the haversine from coordinates (in build()).
        let summaryDistance = delegate.lapDistanceSum > 0 ? delegate.lapDistanceSum
            : (delegate.maxCumulativeDistance > 0 ? delegate.maxCumulativeDistance : nil)
        let summaryEnergy = delegate.calorieSum > 0 ? Double(delegate.calorieSum) : nil

        return ActivityFileImporter.build(
            kind: .tcx,
            samples: delegate.samples,
            sportHint: delegate.sport,
            summaryDistanceM: summaryDistance,
            summaryEnergyKcal: summaryEnergy,
            summaryAvgHr: nil,                 // computed from samples for honesty (lap avgs vary in meaning)
            summaryMaxHr: delegate.lapMaxHr,   // file's own max if it stated one
            summaryAscentM: nil,
            skipped: delegate.skipped
        )
    }
}

// MARK: - Delegate

private final class TcxDelegate: NSObject, XMLParserDelegate {
    var samples: [ActivityFileImporter.TrackSample] = []
    var sport: String?
    var skipped = 0
    var aborted = false

    // Summaries accumulated across laps.
    var lapDistanceSum = 0.0
    var calorieSum = 0
    var lapMaxHr: Int?
    var maxCumulativeDistance = 0.0

    private var depth = 0
    private var text = ""
    private var elementStack: [String] = []

    private var inTrackpoint = false
    private var curLat: Double?
    private var curLon: Double?
    private var curEle: Double?
    private var curTime: Date?
    private var curHr: Int?

    // HeartRateBpm wraps a <Value>; track which HR context the <Value> belongs to.
    private enum HrContext { case none, trackpoint, lapMax }
    private var hrContext: HrContext = .none

    private let maxDepth = 96

    private static func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        depth += 1
        if depth > maxDepth { aborted = true; parser.abortParsing(); return }
        text = ""
        let local = Self.localName(elementName)
        elementStack.append(local)

        switch local {
        case "Activity":
            if sport == nil, let s = attributeDict["Sport"], !s.isEmpty { sport = s }
        case "Trackpoint":
            inTrackpoint = true
            curLat = nil; curLon = nil; curEle = nil; curTime = nil; curHr = nil
        case "HeartRateBpm":
            hrContext = .trackpoint
        case "MaximumHeartRateBpm":
            hrContext = .lapMax
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 4096 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            depth -= 1
            if !elementStack.isEmpty { elementStack.removeLast() }
        }
        if aborted { return }
        let local = Self.localName(elementName)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "LatitudeDegrees":  if inTrackpoint { curLat = Double(trimmed) }
        case "LongitudeDegrees": if inTrackpoint { curLon = Double(trimmed) }
        case "AltitudeMeters":   if inTrackpoint, let v = Double(trimmed), v.isFinite { curEle = v }
        case "Time":             if inTrackpoint { curTime = GpxDelegateTimeBridge.parse(trimmed) }
        case "Value":
            // <Value> inside HeartRateBpm / MaximumHeartRateBpm.
            switch hrContext {
            case .trackpoint: if inTrackpoint { curHr = ActivityFileImporter.validHr(Double(trimmed)) }
            case .lapMax:     if let hr = ActivityFileImporter.validHr(Double(trimmed)) { lapMaxHr = max(lapMaxHr ?? 0, hr) }
            case .none:       break
            }
        case "HeartRateBpm", "MaximumHeartRateBpm":
            hrContext = .none
        case "DistanceMeters":
            // Cumulative inside a Trackpoint; a per-lap total when directly under a Lap.
            if let v = Double(trimmed), v.isFinite, v >= 0 {
                if inTrackpoint {
                    maxCumulativeDistance = max(maxCumulativeDistance, v)
                } else if elementStack.dropLast().last == "Lap" {
                    lapDistanceSum += v
                }
            }
        case "Calories":
            if let v = Int(trimmed), v >= 0, v < 100_000 { calorieSum += v }
        case "Trackpoint":
            finishPoint()
            inTrackpoint = false
        default:
            break
        }
        text = ""
    }

    private func finishPoint() {
        let point = ActivityFileImporter.validCoordinate(lat: curLat, lon: curLon)
        // A Trackpoint with neither a coordinate nor time nor HR is noise — count it skipped.
        if point == nil && curTime == nil && curHr == nil {
            skipped += 1
            return
        }
        if samples.count >= ActivityFileImporter.maxPoints { aborted = true; return }
        samples.append(.init(time: curTime, point: point, elevationM: curEle, hr: curHr))
    }
}

/// Tiny bridge so the TCX delegate (a separate private type) reuses the same ISO time parsing as GPX
/// without exposing GpxDelegate's private method. Both defer to the shared WHOOP/ISO parser.
enum GpxDelegateTimeBridge {
    static func parse(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return WhoopTime.parse(t, offsetMinutes: 0)
    }
}
