import Foundation
#if canImport(FoundationXML)
// corelibs Foundation moved the event-driven XML parser into its own module; Darwin keeps it in
// Foundation. Conditional so one import serves both, with no #if at the use sites.
import FoundationXML
#endif

// MARK: - GPX parser (the universal GPS-track format)
//
// GPX 1.0/1.1: <gpx><trk><trkseg><trkpt lat="" lon=""><ele/><time/>
//   <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr/><gpxtpx:cad/> … (Garmin), and the
//   Cluetrust <gpxdata:hr/> variant. Also reads <rtept> (route points) and <wpt> only as a fallback
//   when there's no track. Namespace prefixes are ignored — we match on the LOCAL element name, so
//   gpxtpx:hr, ns3:hr and a bare hr all resolve. Sport is read from <type> when present.
//
// Built on Foundation's event-driven `XMLParser` (no external dep). The delegate is hardened against
// hostile input: element nesting depth is capped, the trackpoint count is capped (DoS), and a
// billion-laughs-style entity expansion is refused by disabling external-entity / DTD resolution.
// Conceptually adapted from the structure of CoreGPX (MIT) / ticofab android-gpx-parser (Apache);
// this is NOOP's own clean implementation, no upstream code vendored.

enum GpxParser {

    static func parse(data: Data) -> ActivityFileImportResult {
        let delegate = GpxDelegate()
        let parser = XMLParser(data: BOM.stripUTF8(data))
        parser.delegate = delegate
        // SECURITY: never resolve external entities or external DTDs — blocks XXE and the
        // "billion laughs" entity-expansion DoS. We only ever read local element text.
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        let ok = parser.parse()
        // A hard XML error after some points still keeps what we decoded (tolerant import) — but if the
        // delegate aborted because the file blew a guard, treat it as no-activity rather than partial.
        if delegate.aborted {
            return ActivityFileImportResult(activity: nil, kind: .gpx, skipped: delegate.skipped)
        }
        _ = ok
        return ActivityFileImporter.build(
            kind: .gpx,
            samples: delegate.samples,
            sportHint: delegate.sport,
            summaryDistanceM: nil,            // GPX carries no reliable total-distance summary
            summaryEnergyKcal: nil,
            summaryAvgHr: nil,
            summaryMaxHr: nil,
            summaryAscentM: nil,
            skipped: delegate.skipped
        )
    }
}

// MARK: - Delegate

private final class GpxDelegate: NSObject, XMLParserDelegate {
    var samples: [ActivityFileImporter.TrackSample] = []
    var sport: String?
    var skipped = 0
    var aborted = false

    // Current-element scratch.
    private var depth = 0
    private var text = ""
    private var inTrkpt = false
    private var curLat: Double?
    private var curLon: Double?
    private var curEle: Double?
    private var curTime: Date?
    private var curHr: Int?
    /// Element local-name stack so we can attribute parsed text to the right field.
    private var elementStack: [String] = []

    /// Guards (DoS): a real GPX is shallow (gpx>trk>trkseg>trkpt>extensions>ext>hr ≈ depth 8). 64 is a
    /// wide ceiling; beyond it we abort rather than recurse a hostile tree. The point cap is enforced
    /// as we append.
    private let maxDepth = 64

    private static func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...]).lowercased()
        }
        return name.lowercased()
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
        case "trkpt", "rtept", "wpt":
            inTrkpt = true
            curLat = attributeDict["lat"].flatMap(Double.init)
            curLon = attributeDict["lon"].flatMap(Double.init)
            curEle = nil; curTime = nil; curHr = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Cap accumulated text per element so a giant text node can't balloon memory.
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
        case "ele":
            if inTrkpt, let v = Double(trimmed), v.isFinite { curEle = v }
        case "time":
            if inTrkpt { curTime = Self.parseTime(trimmed) }
        case "hr":
            // Garmin gpxtpx:hr or Cluetrust gpxdata:hr — both end in local name "hr".
            if inTrkpt { curHr = ActivityFileImporter.validHr(Double(trimmed)) }
        case "heartrate":
            if inTrkpt, curHr == nil { curHr = ActivityFileImporter.validHr(Double(trimmed)) }
        case "type":
            // <trk><type>running</type> or top-level <type> — first non-empty wins as the sport hint.
            if sport == nil, !trimmed.isEmpty, !inTrkpt || elementStack.contains("trk") { sport = trimmed }
        case "trkpt", "rtept", "wpt":
            finishPoint()
            inTrkpt = false
        default:
            break
        }
        text = ""
    }

    private func finishPoint() {
        guard let point = ActivityFileImporter.validCoordinate(lat: curLat, lon: curLon) else {
            // A point with no valid coordinate is only useful if it still carries a time + HR (a watch
            // can log HR-only trackpoints indoors). Keep those; otherwise count as skipped.
            if curTime != nil || curHr != nil {
                appendSample(.init(time: curTime, point: nil, elevationM: curEle, hr: curHr))
            } else {
                skipped += 1
            }
            return
        }
        appendSample(.init(time: curTime, point: point, elevationM: curEle, hr: curHr))
    }

    private func appendSample(_ s: ActivityFileImporter.TrackSample) {
        if samples.count >= ActivityFileImporter.maxPoints { aborted = true; return }
        samples.append(s)
    }

    /// Parse a GPX/ISO-8601 timestamp (`2026-06-01T10:00:00Z`, with optional fractional seconds /
    /// offset). Reuses the shared WHOOP/ISO parser so all importers agree on time handling.
    static func parseTime(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return WhoopTime.parse(t, offsetMinutes: 0)
    }
}
