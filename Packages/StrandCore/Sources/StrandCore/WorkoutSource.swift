import Foundation
import WhoopStore
import StrandAnalytics   // WorkoutsTrace: the dedup-decision line formatter for the Workouts test mode

// Moved from the app (Android plan B3 step 4): which source a workout row came from and how duplicates of one
// session across sources collapse. The localized sport names stay in the app as an extension
// (`Strand/Data/WorkoutSource.swift`), so the string catalogue keeps extracting them.

/// Origin of a workout row, classified from its stored `source` column. The macOS read model
/// (`WorkoutRow`) carries no `deviceId`, so the row's origin has to be recovered from `source`.
/// Stored values today:
///   - "whoop"        — WhoopImporter (imported WHOOP session)
///   - "apple_health" / "apple-health" — AppleHealthImport
///   - "manual"       — AppModel.endWorkout (v1.67 live session) AND the retro add/edit sheet
///   - "oura-api"     — Oura cloud sync (`OuraSyncWriter`). The stored `source` column carries Oura's
///                       OWN origin ("manual", "autodetected", "confirmed"), so `Repository` rewrites it to
///                       this id on read — see `normalizedOuraRow`.
///   - "my-whoop-noop"— legacy IntelligenceEngine detected bouts (source == the computed deviceId,
///                       i.e. it ends in "-noop"). These remain readable/editable but are no longer
///                       created or reconciled by `analyzeRecent`.
///
/// Classification order matters: "-noop" is checked BEFORE "whoop" because the computed id
/// "my-whoop-noop" also contains the substring "whoop".
public enum WorkoutSource: Equatable, Sendable {
    case whoop, apple, detected, manual, lifting, activityFile, hevy, oura

    /// Canonical Apple Health source id written by new imports. The early rows used the underscore
    /// spelling, so reads must accept both — see `isAppleHealth`.
    public static let appleHealthSource = "apple-health"
    /// The namespace, and after `normalizedOuraRow` the source, of workouts synced from Oura's cloud.
    public static let ouraSource = "oura-api"
    /// The source of workouts synced from the Hevy API (`HevySource.id` in the app).
    public static let hevySource = "hevy"
    private static let legacyAppleHealthSource = "apple_health"

    public static func classify(_ source: String) -> WorkoutSource {
        let s = source.lowercased()
        if s.hasPrefix("native-training") { return .manual }
        if s == ouraSource { return .oura }
        if s.hasSuffix("-noop") { return .detected }   // BEFORE whoop: "my-whoop-noop" contains "whoop"
        if s == "manual" { return .manual }
        if s == "lifting" { return .lifting }          // imported Hevy / Liftosaur strength CSV/JSON
        // API-synced Hevy sessions. A source of their OWN, not folded into `.lifting`: the two lanes can
        // hold the SAME session (someone who imported a CSV export before connecting the API), and
        // keeping them apart is what lets `dedupCrossSource` collapse that pair instead of one lane
        // silently overwriting the other's history.
        if s == hevySource { return .hevy }
        if s == "activity-file" { return .activityFile } // imported GPX / TCX / FIT activity file
        if isAppleHealth(s) { return .apple }          // both spellings → Apple Health
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// True for an Apple Health workout row regardless of which spelling it was stored under —
    /// the canonical `apple-health` or the legacy `apple_health`. Case-insensitive. Counts that
    /// filter Apple-logged workouts (Today, the Apple Health page) MUST go through this so existing
    /// underscore rows still tally.
    public static func isAppleHealth(_ source: String) -> Bool {
        let s = source.lowercased()
        return s == appleHealthSource || s == legacyAppleHealthSource
    }



    /// The camelCase splitter shared by the display and KEY paths. Deliberately NOT localized: the
    /// key path below must be locale-stable.
    public static func splitCamelCase(_ sport: String) -> String {
        if sport.isEmpty || sport.contains(" ") { return sport }
        var out = ""
        var prev: Character?
        for ch in sport {
            if let p = prev, ch.isUppercase, !p.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    /// The locale-stable editable form: what an edit field should SEED so a save round-trips a stable
    /// token ("Activity", never a translated word that would split cross-source dedup per language).
    public static func editableSport(_ sport: String) -> String {
        sport == "detected" ? "Activity" : splitCamelCase(sport)
    }

    // MARK: - Dismissed legacy detected bouts
    //
    // Before #2187 the engine wiped + re-derived "detected" rows every run, so the durable "this isn't a
    // workout" record had to be a list of dismissed spans in UserDefaults. New passes preserve history
    // and create no such rows, but the tombstones remain load-bearing for existing databases and suppress
    // a matching confirmation candidate during the transition. (#107/#2187)

    /// UserDefaults key holding the dismissed spans as "startTs:endTs" strings.
    public static let dismissedDefaultsKey = "workouts.dismissedDetected"

    /// Parse "startTs:endTs" spans (UserDefaults string array). Malformed / non-positive-width
    /// entries are dropped so a corrupt value can never hide everything.
    public static func parseDismissedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// The dismissed spans as `[start, end)` ranges, as the daily analysis excludes them from Effort.
    public static func dismissedWindows(_ raw: [String]) -> [Range<Int>] {
        parseDismissedSpans(raw).map { $0.start ..< $0.end }
    }

    /// The "startTs:endTs" token persisted for a dismissed row (caller appends it to the defaults list).
    public static func dismissedToken(for row: WorkoutRow) -> String { "\(row.startTs):\(row.endTs)" }

    /// Read-time filter: a legacy DETECTED row overlapping any dismissed span is hidden. Imported/manual
    /// rows are never auto-hidden. Half-open overlap test: `row.start < span.end && span.start < row.end`.
    public static func isDismissed(_ row: WorkoutRow, spans: [(start: Int, end: Int)]) -> Bool {
        classify(row.source) == .detected
            && spans.contains { row.startTs < $0.end && $0.start < row.endTs }
    }

    // MARK: - Cross-source dedup (#687)
    //
    // The SAME activity can land twice: once live, Bluetooth-tracked under the strap (rich — real HR
    // trace, strain, zones, route), and once imported from Health Connect / Apple Health for the same
    // window (thin — usually just duration + calories). They sit under different deviceIds/sources, so
    // the workout list shows both as separate sessions. Collapse a pair that is clearly the same bout
    // (overlapping time window + same sport) to a single richer entry.
    //
    // Pure + deterministic so both platforms and the unit test share one rule. Run AFTER the dismissed
    // filter, BEFORE the final sort, on the combined multi-source list.

    /// Normalised sport key for cross-source matching. Folds the WHOOP camelCase token and a
    /// human-readable import label to the same key ("TraditionalStrengthTraining" and
    /// "Traditional Strength Training" → "traditionalstrengthtraining"), case- and space-insensitive,
    /// so the same activity matches across sources. "detected"/"Activity" both fold to "activity".
    /// LOCALE-STABLE by construction: computed from the raw token, never the localized display (a
    /// localized word here would vary the dedup key and the trace allowlist per user language).
    public static func sportKey(_ sport: String) -> String {
        editableSport(sport).lowercased().filter { !$0.isWhitespace }
    }

    /// The set of `sportKey`s for the named catalogue (Running, Cycling, … Padel, Other), computed once.
    /// Used ONLY by the TRACE path to decide whether a key is a known, non-PII catalogue sport.
    private static let catalogSportKeys: Set<String> =
        Set(WorkoutCatalog.all.map { sportKey($0.name) })

    /// PRIVACY (TRACE PATH ONLY): a redaction-safe sport key for the Workouts test-mode trace. `sportKey`
    /// returns a free-typed name verbatim (folded), so a user-named sport like "Johns Birthday 5k" would
    /// otherwise surface as `sport=johnsbirthday5k` in the export, which `redactPii` cannot catch. Here we
    /// emit the key ONLY when it matches the known named catalogue; any off-catalogue / free-text sport
    /// folds to the generic "custom" so genuine user text can never enter a shared bundle. The user-facing
    /// `displaySport` is unchanged - this is purely the diagnostic-line token. "detected"/"Activity" fold to
    /// "activity" via `sportKey` and that IS a catalogue-independent known token, so it is allowed through.
    public static func traceSportKey(_ sport: String) -> String {
        let key = sportKey(sport)
        if key == "activity" { return key }   // the detector's neutral token, never user text
        return catalogSportKeys.contains(key) ? key : "custom"
    }

    /// How many "rich" captured signals a row carries — the tiebreak for which duplicate to keep.
    /// A live-tracked strap session scores high (HR trace, peak, strain, zones, distance); a thin
    /// import scores low. Energy is the most commonly-present import field so it is weighted lowest.
    public static func richness(_ row: WorkoutRow) -> Int {
        var n = 0
        if row.avgHr != nil { n += 1 }
        if row.maxHr != nil { n += 1 }
        if row.strain != nil { n += 1 }
        if let z = row.zonesJSON, !z.isEmpty { n += 1 }
        if let d = row.distanceM, d > 0 { n += 1 }
        if let k = row.energyKcal, k > 0 { n += 1 }
        return n
    }

    /// True when two rows are the SAME activity from different sources: same normalised sport AND their
    /// time windows overlap by more than half of the shorter session. The >50%-of-shorter test (not bare
    /// touching) keeps two genuinely back-to-back same-sport sessions distinct while still catching the
    /// small start/end drift between a live capture and its import.
    public static func sameActivity(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        sportKey(a.sport) == sportKey(b.sport) && overlapsInTime(a, b)
    }

    /// The time-overlap half of `sameActivity`: the two windows overlap by more than half of the shorter
    /// session. Sport equality is checked separately — `collapseCrossSource` buckets rows by sport, so within
    /// a bucket only this (allocation-free) half remains, which is what makes the collapse walk near-linear.
    private static func overlapsInTime(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Of two same-activity rows, the one to KEEP. Prefer the richer (more captured signals); on a tie
    /// prefer the strap-native source (live/manual/detected/whoop carry the real trace) over a thin
    /// import (Apple Health / Health Connect); final tie → the longer session, then `a` (stable).
    public static func preferred(_ a: WorkoutRow, _ b: WorkoutRow) -> WorkoutRow {
        let ra = richness(a), rb = richness(b)
        if ra != rb { return ra > rb ? a : b }
        let ia = classify(a.source) == .apple, ib = classify(b.source) == .apple
        if ia != ib { return ia ? b : a }   // keep the non-import on a richness tie
        let da = a.endTs - a.startTs, db = b.endTs - b.startTs
        if da != db { return da > db ? a : b }
        return a
    }

    // MARK: - Detected-vs-real overlap collapse (#975)
    //
    // Grandfathered generic detections can overlap a real workout logged later. `sameActivity` cannot collapse
    // that pair because their SPORTS differ ("detected" vs the user's sport), so the wider generic row would
    // otherwise remain beside the real one indefinitely. This read-time guard hides a DETECTED row when its
    // window overlaps a REAL (non-detected) session by more than half of the shorter of the two. The
    // >50%-of-shorter test (not bare touching) keeps a genuinely separate back-to-back session distinct,
    // matching `sameActivity`'s overlap rule. It runs BEFORE same-sport cross-source dedup.

    /// True when `detected` (a detected bout) is a redundant shadow of `real` (a logged session of any source
    /// other than detected): their windows overlap by more than half of the shorter session. Order matters ,
    /// `detected` must be the detected row and `real` a non-detected row; the caller enforces that.
    public static func detectedShadowsReal(_ detected: WorkoutRow, _ real: WorkoutRow) -> Bool {
        let overlap = min(detected.endTs, real.endTs) - max(detected.startTs, real.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(detected.endTs - detected.startTs, real.endTs - real.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Drop every DETECTED row whose window shadows a REAL (non-detected) session in the same list (#975), so
    /// the live/manual session and its detected twin never both show. Order-stable; a list with no detected
    /// row, or no real row, passes through unchanged. Runs before `dedupCrossSource`.
    public static func dropDetectedShadows(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        let reals = rows.enumerated()
            .filter { classify($0.element.source) != .detected }
            .sorted { lhs, rhs in
                lhs.element.startTs == rhs.element.startTs
                    ? lhs.offset < rhs.offset
                    : lhs.element.startTs < rhs.element.startTs
            }
        guard !reals.isEmpty else { return rows }
        var dropped = Set<Int>()
        var nextReal = 0
        var active: [(offset: Int, element: WorkoutRow)] = []
        for detected in rows.enumerated()
            .filter({ classify($0.element.source) == .detected })
            .sorted(by: { lhs, rhs in
                lhs.element.startTs == rhs.element.startTs
                    ? lhs.offset < rhs.offset
                    : lhs.element.startTs < rhs.element.startTs
            }) {
            while nextReal < reals.count, reals[nextReal].element.startTs < detected.element.endTs {
                active.append(reals[nextReal])
                nextReal += 1
            }
            active.removeAll { $0.element.endTs <= detected.element.startTs }
            if active.contains(where: { detectedShadowsReal(detected.element, $0.element) }) {
                dropped.insert(detected.offset)
            }
        }
        return rows.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    /// Collapse cross-source duplicates of the same activity, keeping the richer row of each pair.
    /// Order-stable: walks the input once, and a row that duplicates one already kept is dropped (with
    /// the kept row swapped for the richer of the two). Single-source lists pass through unchanged.
    /// #975: a DETECTED bout that shadows a real logged session is dropped FIRST so the transient
    /// live+detected duplicate never shows and can't pollute the Effort/HR read-out.
    public static func dedupCrossSource(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        collapseCrossSource(dropDetectedShadows(rows))
    }

    /// The shared cross-source collapse walk behind `dedupCrossSource` and `dedupCrossSourceTrace`.
    /// Rows are bucketed by sport and swept in timestamp order. Only intervals still open at the candidate's
    /// start stay active, so a ten-year list of same-sport walking workouts no longer compares every entry
    /// with every prior entry. The final array is reconstructed in original order and every component keeps
    /// its earliest input slot, preserving the UI's stable ordering while selecting the same richer winner.
    /// `onMerge` is invoked with (winner, loser) for each collapsed pair so the trace path can record it.
    private static func collapseCrossSource(
        _ input: [WorkoutRow],
        onMerge: ((_ winner: WorkoutRow, _ loser: WorkoutRow) -> Void)? = nil
    ) -> [WorkoutRow] {
        let buckets = Dictionary(grouping: input.indices, by: { sportKey(input[$0].sport) })
        var removed = Set<Int>()
        var replacements: [Int: WorkoutRow] = [:]

        for indices in buckets.values {
            let ordered = indices.sorted { lhs, rhs in
                if input[lhs].startTs != input[rhs].startTs { return input[lhs].startTs < input[rhs].startTs }
                if input[lhs].endTs != input[rhs].endTs { return input[lhs].endTs < input[rhs].endTs }
                return lhs < rhs
            }
            // Original input index of each currently-open component. A replacement row lives at the
            // component's earliest index so the final list remains order-stable.
            var active: [Int] = []
            for index in ordered {
                let row = input[index]
                active.removeAll { (replacements[$0] ?? input[$0]).endTs <= row.startTs }
                let matches = active.filter { overlapsInTime(replacements[$0] ?? input[$0], row) }
                guard let oldAnchor = matches.min() else {
                    active.append(index)
                    continue
                }

                let existing = replacements[oldAnchor] ?? input[oldAnchor]
                let winner = preferred(existing, row)
                onMerge?(winner, winner == existing ? row : existing)
                let anchor = min(oldAnchor, index)
                let loserSlot = max(oldAnchor, index)
                replacements[anchor] = winner
                removed.insert(loserSlot)
                if anchor != oldAnchor {
                    replacements.removeValue(forKey: oldAnchor)
                    if let position = active.firstIndex(of: oldAnchor) { active[position] = anchor }
                }
            }
        }
        return input.indices.compactMap { index in
            removed.contains(index) ? nil : (replacements[index] ?? input[index])
        }
    }

    /// A short, source-only descriptor of a row for the Workouts test-mode dedup trace ("strap" / "apple" /
    /// "detected" / "manual" / "lifting" / "activityFile"). No timestamps or free text.
    public static func sourceLabel(_ row: WorkoutRow) -> String {
        switch classify(row.source) {
        case .whoop:        return "strap"
        case .apple:        return "apple"
        case .detected:     return "detected"
        case .manual:       return "manual"
        case .lifting:      return "lifting"
        case .activityFile: return "activityFile"
        case .hevy:         return "hevy"
        case .oura:         return "oura"
        }
    }

    /// An Oura workout row as the rest of the app reads it.
    ///
    /// Two columns arrive in Oura's vocabulary rather than this app's. `source` holds Oura's own origin
    /// enum, and its "manual" would classify as a NOOP manual row — editable and deletable through
    /// the strap namespaces, where the delete finds nothing and the row reappears. `sport` is Oura's
    /// activity token ("strength_training"), which the cross-source dedup cannot match against the same
    /// session arriving through Apple Health or the native logger ("Strength Training"). Rewritten at
    /// read time rather than in the writer so rows already stored are corrected too, and so the store's
    /// natural key — which includes the sport — is left exactly as it was written.
    public static func normalizedOuraRow(_ row: WorkoutRow) -> WorkoutRow {
        WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: ouraSport(row.sport),
                   source: ouraSource, durationS: row.durationS, energyKcal: row.energyKcal,
                   avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain, distanceM: row.distanceM,
                   zonesJSON: row.zonesJSON, notes: row.notes, steps: row.steps)
    }

    /// "strength_training" / "strengthTraining" -> "Strength Training"; "walking" -> "Walking".
    public static func ouraSport(_ activity: String) -> String {
        let spaced = splitCamelCase(activity.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " "))
        let words = spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return words.isEmpty ? "Workout" : words.joined(separator: " ")
    }

    /// Diagnostic twin of `dedupCrossSource(...)` for the Workouts & GPS test mode: returns the BYTE-IDENTICAL
    /// kept list (the SAME walk, the SAME `preferred` choice) plus a trace line per collapsed pair naming the
    /// kept vs dropped source and their richness. The kept output equals `dedupCrossSource(...)` exactly, so
    /// the trace can never diverge from the list the screen shows. Only called when the mode is on.
    /// #975: it FIRST drops any detected shadow of a real session (the SAME `dropDetectedShadows` step the
    /// plain path runs) and emits one `detectedBout verdict=droppedShadow` line per drop, so the export shows
    /// exactly which detected twin was suppressed to keep the live/manual session single.
    public static func dedupCrossSourceTrace(_ rows: [WorkoutRow]) -> (kept: [WorkoutRow], trace: [String]) {
        var lines: [String] = []
        // Detected-shadow drop first (byte-identical to dedupCrossSource's `dropDetectedShadows`), tracing each.
        let reals = rows.filter { classify($0.source) != .detected }
        var input: [WorkoutRow] = []
        input.reserveCapacity(rows.count)
        for row in rows {
            if classify(row.source) == .detected,
               let hit = reals.first(where: { detectedShadowsReal(row, $0) }) {
                let durMin = max(0, (row.endTs - row.startTs) / 60)
                lines.append(WorkoutsTrace.detectedBoutLine(
                    verdict: "droppedShadow", durMin: durMin, avgBpm: row.avgHr ?? 0,
                    overlapSource: sourceLabel(hit)))
                continue
            }
            input.append(row)
        }
        // Same bucketed collapse as the plain path, so the kept list can never diverge from what the screen
        // shows; the callback records one dedup line per collapsed pair. traceSportKey reads the winner's
        // sport — same sportKey as the loser (they matched), so the emitted token is stable either way.
        let kept = collapseCrossSource(input) { winner, loser in
            lines.append(WorkoutsTrace.dedupLine(
                sportKey: traceSportKey(winner.sport),   // PRIVACY: catalogue key or "custom", never free text
                keptSource: sourceLabel(winner), droppedSource: sourceLabel(loser),
                keptRichness: richness(winner), droppedRichness: richness(loser)))
        }
        return (kept, lines)
    }

    // MARK: - Building / preserving rows

    /// Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, zonesJSON, notes,
    /// steps) over from the row being edited. A v1.67 live-tracked session has real captured
    /// strain/maxHr; rebuilding the row from the sheet's inputs alone would silently wipe them on an
    /// edit. No-op for a fresh add (`old == nil`). `distanceM` is NOW a sheet field (#1195), so it comes
    /// from the freshly built `row` (the sheet pre-fills it from the edited row, so an untouched field
    /// preserves the captured GPS distance and a cleared one clears it) rather than being force-carried
    /// from `old`. `steps` (#1058) has no sheet field at all, so it is carried like the others (#1444).
    public static func preservingCaptured(_ row: WorkoutRow, from old: WorkoutRow?) -> WorkoutRow {
        guard let old else { return row }
        return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                          source: row.source, durationS: row.durationS,
                          energyKcal: row.energyKcal, avgHr: row.avgHr,
                          maxHr: old.maxHr, strain: old.strain, distanceM: row.distanceM,
                          zonesJSON: old.zonesJSON, notes: old.notes, steps: old.steps)
    }

    /// The span cap a manual workout may cover, shared by both builders and the sheet's binding.
    public static let maxManualSpanSeconds = 24 * 60 * 60

    /// Shortest manual session worth keeping, matching the live-session floor in `AppModel.endWorkout`.
    ///
    /// The duration-shaped front door already enforced this by accident, since it counts whole minutes and
    /// rejects zero. The SPAN-shaped door did not, and that is the one the Add/Edit sheet uses, so a
    /// start and end thirty seconds apart made a row the live path would have discarded.
    ///
    /// Enforcing it here rather than at the sheet means the Save button disables itself and the sheet's
    /// existing validation note explains why, with no new UI and no new string.
    public static let minManualSpanSeconds = 60

    /// The end a given duration implies. The sheet uses this when the user types a duration, so a typed
    /// duration and a picked end produce identical rows.
    public static func endForDuration(start: Date, durationMin: Int) -> Date {
        Date(timeIntervalSince1970: start.timeIntervalSince1970 + TimeInterval(durationMin * 60))
    }

    /// Whole minutes in a span, for the duration field's DISPLAY.
    ///
    /// Rounds, so a stored 45m17s bout reads as "45". That rounding is display-only now: the sheet keeps
    /// the exact end as its state of record and saves that, where it previously round-tripped the span
    /// through this number and wrote the rounded end back. Editing a detected workout's sport therefore
    /// no longer shortens it by up to 30 seconds.
    public static func spanDurationMin(start: Date, end: Date) -> Int {
        // .rounded() is half-away-from-zero, matching Kotlin's Math.round on the positive spans this
        // sees, so the two platforms show the same minute for the same stored row.
        Int(((end.timeIntervalSince1970 - start.timeIntervalSince1970) / 60).rounded())
    }

    /// Where the end lands when the START moves.
    ///
    /// Moving the start keeps the workout the same LENGTH rather than pinning the end, which is what a
    /// user correcting "this began an hour earlier than I said" means. Pinning the end instead would
    /// silently restretch the duration on every start correction.
    public static func endAfterStartMove(oldStart: Date, oldEnd: Date, newStart: Date) -> Date {
        Date(timeIntervalSince1970: newStart.timeIntervalSince1970
             + (oldEnd.timeIntervalSince1970 - oldStart.timeIntervalSince1970))
    }

    /// Build a retroactive manual workout from an explicit SPAN.
    ///
    /// The row has always been stored as `startTs`/`endTs`, so this is the shape the storage already
    /// speaks; `buildManualRow` is the duration-shaped front door that delegates here (#2034). Split out
    /// so the sheet can offer an end time without the value making a lossy round trip through whole
    /// minutes.
    ///
    /// Validation is the duration form's, re-expressed: a span must be positive, at most
    /// `maxManualSpanSeconds`, and must not end in the future. Twin of Android
    /// `WorkoutEditing.buildManualRowFromSpan`.
    public static func buildManualRowFromSpan(start: Date, end: Date, sport: String,
                                       avgHr: Int?, energyKcal: Double?, distanceM: Double? = nil,
                                       now: Date = Date()) -> WorkoutRow? {
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, start <= now else { return nil }
        let s = Int(start.timeIntervalSince1970)
        let e = Int(end.timeIntervalSince1970)
        guard s > 0, e > s else { return nil }
        let spanSeconds = e - s
        guard spanSeconds >= minManualSpanSeconds else { return nil }
        guard spanSeconds <= maxManualSpanSeconds else { return nil }
        guard e <= Int(now.timeIntervalSince1970) else { return nil }
        if let hr = avgHr, !(25...250).contains(hr) { return nil }
        if let k = energyKcal, k < 0 || k > 20_000 { return nil }
        // Distance 0-1000 km (#1195): rejects a negative or absurd manual entry. 1000 km comfortably
        // covers any single session (an Ironman bike is 180 km, an ultra 160 km).
        if let d = distanceM, d < 0 || d > 1_000_000 { return nil }
        return WorkoutRow(startTs: s, endTs: e, sport: trimmed, source: "manual",
                          durationS: Double(spanSeconds), energyKcal: energyKcal,
                          avgHr: avgHr, maxHr: nil, strain: nil, distanceM: distanceM,
                          zonesJSON: nil, notes: nil, steps: nil)
    }

    /// Build a retroactive manual workout (source "manual", persisted under the strap deviceId by the
    /// caller — where v1.67's live sessions live). Returns nil when the input can't make an honest row.
    /// strain/zones stay nil: with no captured HR window an APPROXIMATE strain is never fabricated.
    ///
    /// The duration-shaped front door. Delegates to `buildManualRowFromSpan` so the two entry points
    /// cannot drift; it keeps the whole-minute bounds and the overflow guard, which only this shape needs.
    public static func buildManualRow(start: Date, durationMin: Int, sport: String,
                               avgHr: Int?, energyKcal: Double?, distanceM: Double? = nil,
                               now: Date = Date()) -> WorkoutRow? {
        guard durationMin > 0, durationMin <= 24 * 60 else { return nil }
        let s = Int(start.timeIntervalSince1970)
        guard s > 0 else { return nil }
        // Reject a row whose END lands in the future: `start <= now` alone still lets `start + duration`
        // overshoot (a start 10 min ago + a 45 min duration ends 35 min ahead). A row ending exactly at
        // `now` stays valid. Twin of Android `WorkoutEditing` (#1067). The end check itself now lives in
        // `buildManualRowFromSpan`; the overflow guard stays HERE, because only this shape does the
        // addition that can overflow. It also runs BEFORE the Int -> TimeInterval -> Int round trip the
        // delegation introduces. That round trip is exact for anything the guards admit: a real timestamp
        // plus at most 24h is ~1.7e9, and Double represents integers exactly to 2^53.
        let durationSeconds = durationMin * 60
        guard durationSeconds <= Int.max - s else { return nil }
        return buildManualRowFromSpan(
            start: start,
            end: Date(timeIntervalSince1970: TimeInterval(s + durationSeconds)),
            sport: sport, avgHr: avgHr, energyKcal: energyKcal, distanceM: distanceM, now: now)
    }
}

// MARK: - Filter predicate (#64)
//
// The Workouts list filters beyond the time range: a SPORT filter (a specific displayed sport, or all)
// and a SOURCE filter (Whoop / Apple / Detected / Manual / Lifting / File, or all), plus a free-text
// SEARCH over the displayed sport name. All three are pure and compose with the time-range window the
// screen already computes, so the whole screen (hero, tiles, breakdown, zones, list) reads one filtered
// set. Kept alongside `WorkoutSource` so both platforms share one rule and the unit test pins it.
