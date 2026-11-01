import Foundation

/// Export a recorded GPS workout route to a standard interchange file (GPX 1.1 or FIT) — the sibling of
/// ``ActivityFileImporter``. Without a heart-rate curve or pauses its bytes match the Kotlin `RouteExport`;
/// the FIT path with them (and FIT sport numbers by the profile) is Swift only. Pure Swift + Foundation
/// (no CoreLocation/UIKit), so it lives in this package, unit-tests without an app, and is covered by
/// `swift-packages.yml`.
///
/// FIDELITY NOTE: the stored route (`RouteMath` polyline) is lat/lon ONLY — no per-point timestamp,
/// elevation or speed is persisted with it, and heart rate lives in the strap store (passed as `heartRate`). (A route NOOP recorded with measured points passes their real
/// times as `recordedTimes` and, when a barometer reported, their heights as `elevations`.) So an export carries the lat/lon track plus per-point timestamps
/// INTERPOLATED evenly across the workout window `[startTs, endTs]` (total duration is exact; instantaneous
/// pace is not), and workout-level metadata (sport, distance, calories, avg/max HR). That's the honest
/// maximum from what's stored, and what Strava / Garmin Connect need to read the track as a timed activity.
public enum RouteExporter {

    public enum Format: String, Sendable, Equatable {
        case gpx, fit
        public var ext: String { rawValue }
        public var label: String { self == .gpx ? "GPX" : "FIT" }
    }

    /// Seconds between the Unix epoch and the FIT epoch (1989-12-31T00:00:00Z).
    static let fitEpoch = 631_065_600

    /// Semicircles per degree — the FIT position unit: `semicircles = degrees × 2^31 / 180`.
    static let semiPerDeg = 2_147_483_648.0 / 180.0

    // MARK: - Public API

    public static func render(
        _ format: Format,
        route: [RoutePoint],
        startTs: Int,
        endTs: Int,
        sport: String?,
        distanceM: Double? = nil,
        energyKcal: Double? = nil,
        avgHr: Int? = nil,
        maxHr: Int? = nil,
        recordedTimes: [Int]? = nil,
        segmentStarts: [Int] = [],
        activeDurationS: Double? = nil,
        elevations: [Double?]? = nil,
        heartRate: [ActivityHRSample] = [],
        pauses: [Pause] = []
    ) -> Data {
        switch format {
        case .gpx:
            return Data(buildGpx(route: route, startTs: startTs, endTs: endTs, sport: sport,
                                 recordedTimes: recordedTimes, segmentStarts: segmentStarts,
                                 elevations: elevations).utf8)
        case .fit:
            return buildFit(route: route, startTs: startTs, endTs: endTs, sport: sport,
                            distanceM: distanceM, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr,
                            recordedTimes: recordedTimes, activeDurationS: activeDurationS,
                            elevations: elevations, heartRate: heartRate, pauses: pauses)
        }
    }

    /// A stretch the wearer paused, in Unix seconds. The FIT export writes it as a timer stop and start and
    /// leaves out the heart rate sampled inside it, so a reader counts it neither as moving nor as effort.
    public struct Pause: Sendable, Equatable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// Per-point heights aligned with the route, or nil when the array does not match it or holds none.
    static func alignedElevations(_ elevations: [Double?]?, count: Int) -> [Double?]? {
        guard let elevations, elevations.count == count,
              elevations.contains(where: { $0.map(\.isFinite) ?? false }) else { return nil }
        return elevations.map { $0.flatMap { $0.isFinite ? $0 : nil } }
    }

    /// GPX 1.1 track. Each `trkpt` carries lat/lon, an `ele` when a measured height is given, and a `time`;
    /// no HR (none stored).
    /// Takes no distance: GPX 1.1 has no track-level distance element, so a reader derives it from the
    /// trackpoints. FIT does carry one, which is why ``buildFit`` still takes it. Kotlin twin matches.
    public static func buildGpx(
        route: [RoutePoint],
        startTs: Int,
        endTs: Int,
        sport: String?,
        recordedTimes: [Int]? = nil,
        segmentStarts: [Int] = [],
        elevations: [Double?]? = nil
    ) -> String {
        let canon = canonicalSport(sport)
        let times = recordedTimes.flatMap { $0.count == route.count ? $0 : nil }
            ?? interpolatedTimes(route.count, startTs, endTs)
        let heights = alignedElevations(elevations, count: route.count)
        let boundaries = Set(segmentStarts.filter { $0 > 0 && $0 < route.count })
        var s = ""
        s += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"NOOP\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        s += "  <metadata>\n    <time>\(iso(startTs))</time>\n  </metadata>\n"
        s += "  <trk>\n"
        s += "    <name>\(xmlEscape(displaySport(canon)))</name>\n"
        s += "    <type>\(xmlEscape(canon))</type>\n"
        s += "    <trkseg>\n"
        for i in route.indices {
            if boundaries.contains(i) { s += "    </trkseg>\n    <trkseg>\n" }
            let p = route[i]
            s += "      <trkpt lat=\"\(coord(p.lat))\" lon=\"\(coord(p.lon))\">"
            // GPX 1.1 orders `ele` before `time`.
            if let height = heights?[i] { s += "<ele>\(String(format: "%.1f", height))</ele>" }
            s += "<time>\(iso(times[i]))</time></trkpt>\n"
        }
        s += "    </trkseg>\n  </trk>\n</gpx>\n"
        return s
    }

    /// A minimal but well-formed FIT activity file: file_id, one record per point, lap, session, activity,
    /// and the trailing CRC-16. Decodes back through ``ActivityFileImporter`` and imports into Strava /
    /// Garmin Connect.
    ///
    /// `heartRate` adds the per-second curve: a sample in the same second as a route point rides on that
    /// point's record, every other one gets a record of its own (time and heart rate only), which is also
    /// how a workout without a route still carries data. `pauses` become timer events. Without either, the
    /// file is byte for byte what it was before they existed.
    public static func buildFit(
        route: [RoutePoint],
        startTs: Int,
        endTs: Int,
        sport: String?,
        distanceM: Double? = nil,
        energyKcal: Double? = nil,
        avgHr: Int? = nil,
        maxHr: Int? = nil,
        recordedTimes: [Int]? = nil,
        activeDurationS: Double? = nil,
        elevations: [Double?]? = nil,
        heartRate: [ActivityHRSample] = [],
        pauses: [Pause] = []
    ) -> Data {
        let fitSport = fitSportPair(sport)
        let times = recordedTimes.flatMap { $0.count == route.count ? $0 : nil }
            ?? interpolatedTimes(route.count, startTs, endTs)
        let heights = alignedElevations(elevations, count: route.count)
        let stops = mergedPauses(pauses, startTs: startTs, endTs: endTs)
        let pulse = exportableHeartRate(heartRate, startTs: startTs, endTs: endTs, pauses: stops)
        var body: [UInt8] = []

        // file_id (global 0): type=activity, manufacturer=development, time_created.
        defn(&body, local: 0, global: 0, fields: [(0, 1, 0x00), (1, 2, 0x84), (4, 4, 0x86)])
        body.append(0)
        u8(&body, 4); u16(&body, 255); u32(&body, fitTime(startTs))

        // record (global 20): timestamp + position, and altitude (field 2, uint16, scale 5, offset 500)
        // when heights were measured. A point without one carries FIT's invalid 0xFFFF. Heart rate (field 3,
        // uint8) has no such sentinel the importer would honour, so a point with a pulse and one without use
        // two local definitions instead of one with a placeholder.
        var recordFields = [(253, 4, 0x86), (0, 4, 0x85), (1, 4, 0x85)]
        if heights != nil { recordFields.append((2, 2, 0x84)) }
        defn(&body, local: 1, global: 20, fields: recordFields)
        if !pulse.isEmpty {
            defn(&body, local: 5, global: 20, fields: recordFields + [(3, 1, 0x02)])
            defn(&body, local: 6, global: 20, fields: [(253, 4, 0x86), (3, 1, 0x02)])
        }
        // event (global 21): timer (0) start (0) / stop_all (4).
        if !stops.isEmpty { defn(&body, local: 7, global: 21, fields: [(253, 4, 0x86), (0, 1, 0x00), (1, 1, 0x00)]) }

        for item in fitTimeline(times: times, pulse: pulse, pauses: stops, startTs: startTs, endTs: endTs) {
            switch item {
            case let .point(i, bpm):
                body.append(bpm == nil ? 1 : 5)
                u32(&body, fitTime(times[i]))
                s32(&body, semicircles(route[i].lat))
                s32(&body, semicircles(route[i].lon))
                if let heights { u16(&body, fitAltitude(heights[i])) }
                if let bpm { u8(&body, bpm) }
            case let .pulse(ts, bpm):
                body.append(6)
                u32(&body, fitTime(ts))
                u8(&body, bpm)
            case let .timer(ts, running):
                body.append(7)
                u32(&body, fitTime(ts))
                u8(&body, 0)
                u8(&body, running ? 0 : 4)
            }
        }

        let elapsedMs = UInt32(max(0, endTs - startTs)) &* 1000
        let distCenti: UInt32? = distanceM.map { UInt32(max(0, ($0 * 100.0).rounded())) }

        // lap (global 19): external tools expect at least one; our decoder folds it under session.
        // Distance uses the FIT 0xFFFFFFFF "invalid" value when absent — the decoder special-cases it.
        defn(&body, local: 2, global: 19, fields: [(253, 4, 0x86), (2, 4, 0x86), (7, 4, 0x86), (9, 4, 0x86)])
        body.append(2)
        u32(&body, fitTime(endTs)); u32(&body, fitTime(startTs)); u32(&body, elapsedMs)
        u32(&body, distCenti ?? 0xFFFF_FFFF)

        // session (global 18): only the fields we actually have. An absent HR must be truly absent — the
        // importer's validHr accepts 1..300 and would misread a 0xFF sentinel as a real HR of 255.
        var sf: [(Int, Int, Int)] = []
        var sd: [UInt8] = []
        sf.append((253, 4, 0x86)); u32(&sd, fitTime(endTs))
        sf.append((2, 4, 0x86)); u32(&sd, fitTime(startTs))
        sf.append((7, 4, 0x86)); u32(&sd, elapsedMs)
        if let activeDurationS, activeDurationS.isFinite, activeDurationS >= 0 {
            sf.append((8, 4, 0x86)); u32(&sd, UInt32(min(activeDurationS * 1000, Double(UInt32.max))))
        }
        sf.append((5, 1, 0x00)); u8(&sd, fitSport.sport)
        if fitSport.subSport != 0 { sf.append((6, 1, 0x00)); u8(&sd, fitSport.subSport) }
        if let distCenti { sf.append((9, 4, 0x86)); u32(&sd, distCenti) }
        if let energyKcal { sf.append((11, 2, 0x84)); u16(&sd, UInt16(min(max(0, energyKcal.rounded()), 65534))) }
        if let avgHr { sf.append((16, 1, 0x02)); u8(&sd, min(max(avgHr, 0), 254)) }
        if let maxHr { sf.append((17, 1, 0x02)); u8(&sd, min(max(maxHr, 0), 254)) }
        defn(&body, local: 3, global: 18, fields: sf)
        body.append(3)
        body.append(contentsOf: sd)

        // activity (global 34): one session.
        defn(&body, local: 4, global: 34, fields: [(253, 4, 0x86), (1, 2, 0x84), (2, 1, 0x00)])
        body.append(4)
        u32(&body, fitTime(endTs)); u16(&body, 1); u8(&body, 0)

        // 12-byte header + body + CRC-16 over header+body.
        var out: [UInt8] = []
        u8(&out, 12); u8(&out, 0x20); u16(&out, 2140); u32(&out, UInt32(body.count))
        out.append(contentsOf: Array(".FIT".utf8))
        out.append(contentsOf: body)
        let crc = fitCrc(out)
        u16(&out, UInt16(crc))
        return Data(out)
    }

    // MARK: - Timing / units

    /// Per-point Unix seconds, spread evenly across `[startTs, endTs]` (start for a single point).
    static func interpolatedTimes(_ n: Int, _ startTs: Int, _ endTs: Int) -> [Int] {
        if n <= 0 { return [] }
        if n == 1 { return [startTs] }
        let span = Double(max(0, endTs - startTs))
        return (0..<n).map { i in startTs + Int((span * Double(i) / Double(n - 1)).rounded()) }
    }

    private static func fitTime(_ unix: Int) -> UInt32 {
        UInt32(min(max(0, unix - fitEpoch), 0xFFFF_FFFF))
    }

    private static func semicircles(_ deg: Double) -> Int32 {
        let v = (deg * semiPerDeg).rounded(.toNearestOrAwayFromZero)
        if v >= Double(Int32.max) { return Int32.max }
        if v <= Double(Int32.min) { return Int32.min }
        return Int32(v)
    }

    /// ISO-8601 UTC to whole seconds, e.g. `2026-08-11T04:47:38Z`. Computed by hand (civil-from-days) so
    /// it is deterministic and matches the Kotlin `Instant.toString()` twin exactly, with no shared
    /// mutable `DateFormatter`.
    static func iso(_ unix: Int) -> String {
        let days = Int(floor(Double(unix) / 86400.0))
        let secOfDay = unix - days * 86400
        let hh = secOfDay / 3600, mm = (secOfDay % 3600) / 60, ss = secOfDay % 60
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y0 = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = m <= 2 ? y0 + 1 : y0
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, hh, mm, ss)
    }

    /// Fixed 6-dp coordinate — well beyond the polyline's ~1 m (precision-5) resolution.
    private static func coord(_ v: Double) -> String { String(format: "%.6f", v) }

    // MARK: - Sport mapping

    /// Collapse a free-form sport string to one canonical key (the GPS-relevant families).
    static func canonicalSport(_ sport: String?) -> String {
        let s = (sport ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "", "other": return "other"
        case "run", "running", "jog", "jogging", "treadmill": return "run"
        case "cycle", "cycling", "bike", "biking", "ride", "spinning": return "cycle"
        case "walk", "walking", "rucking": return "walk"
        case "hike", "hiking": return "hike"
        case "swim", "swimming": return "swim"
        default: return s
        }
    }

    private static func displaySport(_ canon: String) -> String {
        canon.isEmpty ? canon : canon.prefix(1).uppercased() + canon.dropFirst()
    }

    /// FIT `sport` (session field 5) and `sub_sport` (field 6) for a stored sport name, by the FIT profile
    /// numbers. Strava and Garmin pick the activity type from this pair, so a strength session goes out as
    /// training / strength_training rather than generic. Matched on the name with case, spaces and
    /// punctuation removed, the same key `ActivityMETCatalog` uses; anything unknown is generic.
    static func fitSportPair(_ sport: String?) -> (sport: Int, subSport: Int) {
        let key = (sport ?? "").lowercased().filter { $0.isLetter }
        switch key {
        case "run", "running", "jog", "jogging": return (1, 0)
        case "treadmill", "treadmillrun", "indoorrun", "indoorrunning": return (1, 1)
        case "trailrun", "trailrunning": return (1, 3)
        case "walk", "walking", "rucking", "nordicwalking": return (11, 0)
        case "treadmillwalk", "indoorwalk", "indoorwalking": return (11, 27)
        case "hike", "hiking": return (17, 0)
        case "mountaineering": return (16, 0)
        case "cycle", "cycling", "bike", "biking", "ride": return (2, 0)
        case "indoorcycle", "indoorcycling", "spinning": return (2, 6)
        case "mountainbiking": return (2, 8)
        case "swim", "swimming", "poolswim": return (5, 17)
        case "openwaterswim": return (5, 18)
        case "rowing": return (15, 0)
        case "rowmachine", "indoorrowing": return (15, 14)
        case "elliptical": return (4, 15)
        case "stairclimber", "stairclimbing": return (4, 16)
        case "strength", "strengthtraining", "functionalstrengthtraining", "traditionalstrengthtraining",
             "weightlifting", "weighttraining", "powerlifting", "bodybuilding", "resistancetraining",
             "calisthenics":
            return (10, 20)
        case "hiit", "crossfit", "bootcamp", "cardio": return (10, 26)
        case "yoga": return (10, 43)
        case "pilates": return (10, 44)
        case "stretching", "flexibility": return (10, 19)
        case "boxing", "kickboxing": return (47, 0)
        case "skiing", "alpineskiing": return (13, 0)
        case "crosscountryskiing": return (12, 0)
        case "snowboarding": return (14, 0)
        case "snowshoeing": return (35, 0)
        case "iceskating": return (33, 0)
        case "inlineskating": return (30, 0)
        case "climbing", "rockclimbing": return (31, 0)
        case "kayaking": return (41, 0)
        case "standuppaddleboard", "standuppaddleboarding": return (37, 0)
        case "surfing": return (38, 0)
        case "kiteboarding", "kitesurfing": return (44, 0)
        case "sailing": return (32, 0)
        case "golf": return (25, 0)
        case "tennis": return (8, 0)
        case "basketball": return (6, 0)
        case "soccer", "football": return (7, 0)
        case "americanfootball": return (9, 0)
        case "horsebackriding": return (27, 0)
        case "hunting": return (28, 0)
        case "fishing": return (29, 0)
        default: return (0, 0)
        }
    }

    // MARK: - FIT timeline

    /// One message in the FIT body after the definitions, in time order.
    enum FitItem: Equatable {
        /// Route point `i`, with the pulse of the same second when there is one.
        case point(Int, bpm: Int?)
        /// A second with a pulse and no route point.
        case pulse(Int, bpm: Int)
        /// The timer starting (`true`) or stopping.
        case timer(Int, running: Bool)
    }

    /// Pauses clipped to the workout and merged where they touch, sorted. One that covers nothing is dropped.
    static func mergedPauses(_ pauses: [Pause], startTs: Int, endTs: Int) -> [Pause] {
        let clipped = pauses
            .map { Pause(start: max($0.start, startTs), end: min($0.end, endTs)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var out: [Pause] = []
        for p in clipped {
            if let last = out.last, p.start <= last.end {
                out[out.count - 1].end = max(last.end, p.end)
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// The pulse a FIT record may carry: inside the workout, outside every pause, one sample per second
    /// (the first wins) and within the uint8 range below FIT's invalid 0xFF.
    static func exportableHeartRate(_ samples: [ActivityHRSample], startTs: Int, endTs: Int,
                                    pauses: [Pause]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for s in samples where s.ts >= startTs && s.ts <= endTs && (1...254).contains(s.bpm) {
            guard !pauses.contains(where: { s.ts >= $0.start && s.ts < $0.end }), out[s.ts] == nil else { continue }
            out[s.ts] = s.bpm
        }
        return out
    }

    /// Route points, pulse-only seconds and timer events in time order. At one second a timer start comes
    /// first and a stop last, so the records of that second sit inside the running timer.
    static func fitTimeline(times: [Int], pulse: [Int: Int], pauses: [Pause], startTs: Int,
                            endTs: Int) -> [FitItem] {
        var keyed: [(ts: Int, rank: Int, seq: Int, item: FitItem)] = []
        var used = Set<Int>()
        for (i, ts) in times.enumerated() {
            let bpm = used.contains(ts) ? nil : pulse[ts]
            if bpm != nil { used.insert(ts) }
            keyed.append((ts, 1, keyed.count, .point(i, bpm: bpm)))
        }
        for (ts, bpm) in pulse where !used.contains(ts) {
            keyed.append((ts, 1, keyed.count, .pulse(ts, bpm: bpm)))
        }
        if !pauses.isEmpty {
            keyed.append((startTs, 0, keyed.count, .timer(startTs, running: true)))
            for p in pauses {
                keyed.append((p.start, 2, keyed.count, .timer(p.start, running: false)))
                if p.end < endTs { keyed.append((p.end, 0, keyed.count, .timer(p.end, running: true))) }
            }
            if pauses.last.map({ $0.end < endTs }) ?? true {
                keyed.append((endTs, 2, keyed.count, .timer(endTs, running: false)))
            }
        }
        return keyed.sorted { ($0.ts, $0.rank, $0.seq) < ($1.ts, $1.rank, $1.seq) }.map(\.item)
    }

    // MARK: - XML / byte helpers

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Emit a FIT definition message for `local`/`global` with `fields` (field num, size, base-type),
    /// little-endian.
    private static func defn(_ b: inout [UInt8], local: Int, global: Int,
                             fields: [(Int, Int, Int)]) {
        u8(&b, 0x40 | (local & 0x0F)) // definition record header
        u8(&b, 0)                     // reserved
        u8(&b, 0)                     // architecture: 0 = little-endian
        u16(&b, UInt16(global))
        u8(&b, fields.count)
        for f in fields { u8(&b, f.0); u8(&b, f.1); u8(&b, f.2) }
    }

    private static func u8(_ b: inout [UInt8], _ v: Int) { b.append(UInt8(v & 0xFF)) }
    private static func u16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
    }
    private static func u32(_ b: inout [UInt8], _ v: UInt32) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
        b.append(UInt8((v >> 16) & 0xFF)); b.append(UInt8((v >> 24) & 0xFF))
    }
    private static func s32(_ b: inout [UInt8], _ v: Int32) { u32(&b, UInt32(bitPattern: v)) }

    /// FIT altitude: (metres + 500) × 5 as uint16; 0xFFFF (invalid) when absent or out of range.
    static func fitAltitude(_ metres: Double?) -> UInt16 {
        guard let metres, metres.isFinite else { return 0xFFFF }
        let raw = ((metres + 500) * 5).rounded()
        guard raw >= 0, raw < 0xFFFF else { return 0xFFFF }
        return UInt16(raw)
    }

    /// The standard FIT CRC-16 (nibble-table variant), computed over `data`.
    static func fitCrc(_ data: [UInt8]) -> Int {
        let table = [
            0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
            0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
        ]
        var crc = 0
        for byte in data {
            let b = Int(byte)
            var tmp = table[crc & 0xF]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[b & 0xF]
            tmp = table[crc & 0xF]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[(b >> 4) & 0xF]
        }
        return crc & 0xFFFF
    }
}
