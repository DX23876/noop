import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Strap & data-state + analytics-funnel lines appended to the iOS debug export — the twin of Android's
/// `AndroidDiagnostics.strapAndDataLines` + `funnelLines`. Best-effort and self-reporting: every section is
/// guarded so a header build never throws, and the funnels print the sample counts they read and say plainly
/// when they can't compute, so a shared log never carries a fabricated verdict.
///
/// Two entry points, matching the two export paths:
///   • `strapStateLines()` — SYNC, offline-safe (persisted defaults + timezone). Usable from the scheduled
///     background export, which has no `Repository`.
///   • `dynamicLines(repo:)` — ASYNC, the full block (strap state + data spine + recomputed funnels for the
///     latest night). Used by the interactive "Save…/Share log" buttons, which hold `model.repo`.
enum DebugDataDiagnostics {

    /// Strap identity + timezone from persisted defaults (sync, offline-safe). Mirrors the prefs-backed
    /// portion of the Android strap-state block; keys match the iOS @AppStorage / persisted values.
    static func strapStateLines() -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Strap & data")
        let d = UserDefaults.standard
        let model: String
        switch d.string(forKey: "selectedWhoopModel") {
        case "whoop5": model = "WHOOP 5.0 / MG"
        case "whoop4": model = "WHOOP 4.0"
        default:       model = "unknown (never paired)"
        }
        lines.append("Model:       \(model)")
        lines.append("Firmware:    \(d.string(forKey: "noop.lastFirmware") ?? "unknown (connect to record)")")
        let syncSec = d.double(forKey: "lastSyncedAt")
        lines.append("Last sync:   \(syncSec > 0 ? relTime(Date().timeIntervalSince1970 - syncSec) : "never")")
        lines.append("Timezone:    \(tzLine())")
        return lines
    }

    /// The full dynamic block: strap state + data spine (preloaded `repo.days`) + the REM/skin-temp funnels
    /// recomputed for the most recent night. Async — it reads the on-device store. Never throws.
    @MainActor static func dynamicLines(repo: Repository) async -> [String] {
        var lines = strapStateLines()

        // Data state from the preloaded day spine.
        let days = repo.days
        lines.append("History:     \(days.count) day rows")
        if let s = days.last(where: { ($0.totalSleepMin ?? 0) > 0 }) {
            lines.append("Last sleep:  \(s.day) · \(Int(s.totalSleepMin ?? 0)) min")
        } else { lines.append("Last sleep:  none") }
        if let r = days.last(where: { $0.recovery != nil }) {
            lines.append("Last recov.: \(r.day) · \(Int(r.recovery ?? 0))%")
        } else { lines.append("Last recov.: none") }

        // Workout & imported-activity source breakdown (#28/#29 "counted but not shown" class). Runs BEFORE
        // the funnels since those can early-return, so this always lands in the export.
        lines += await workoutSourceLines(repo: repo)
        lines += await dailyDataLines(repo: repo)
        lines += alarmLines()

        // Funnels for the latest night — best-effort, self-reporting.
        lines.append(String(repeating: "─", count: 40))
        lines.append("Analytics funnels (latest night, best-effort)")
        let nowSec = Int(Date().timeIntervalSince1970)
        guard let cs = await repo.sleepSessions(from: nowSec - 14 * 86400, to: nowSec, limit: 1).last else {
            lines.append("(no sleep session in the last 14 days to analyze)")
            return lines
        }
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        let did = repo.deviceId
        let grav = (try? await store.gravitySamples(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        let hr = await repo.hrSamples(from: cs.startTs, to: cs.endTs, limit: 200_000)
        let rr = (try? await store.rrIntervals(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        let resp = (try? await store.respSamples(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        let skin = (try? await store.skinTempSamples(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        lines.append("Night \(dayStamp(cs.startTs)): grav=\(grav.count) hr=\(hr.count) rr=\(rr.count) resp=\(resp.count) skin=\(skin.count)")
        if grav.isEmpty && hr.isEmpty {
            lines.append("(no raw biometric samples under '\(did)' for this night — expected on a freshly re-added strap; reconnect + let a history sync run, then re-export)")
            return lines
        }
        if let rem = SleepStager.remFunnelDiagnostic(start: cs.startTs, end: cs.endTs, grav: grav, hr: hr, rr: rr, resp: resp) {
            lines.append(rem.summary)
        } else {
            lines.append("REM funnel: insufficient motion data (<2 gravity samples)")
        }
        let det = SleepSession(start: cs.startTs, end: cs.endTs, efficiency: cs.efficiency ?? 0,
                               stages: [], restingHR: cs.restingHr, avgHRV: cs.avgHrv)
        let family: DeviceFamily = (UserDefaults.standard.string(forKey: "selectedWhoopModel") == "whoop5") ? .whoop5 : .whoop4
        lines.append(AnalyticsEngine.skinTempFunnel([det], hr: hr, skinTemp: skin, family: family).summary)
        return lines
    }

    /// Workout & imported-activity source breakdown: the resolved active deviceId + a per-source STORED
    /// workout count + the most-recent workout, so a "workouts not showing" report reveals WHERE workouts
    /// live vs what the Workouts screen loads (#28 strap↔my-whoop, #29 activity-file). Best-effort.
    @MainActor static func workoutSourceLines(repo: Repository) async -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Workouts by source")
        let did = repo.deviceId
        lines.append("Active deviceId: \(did)\(did == "my-whoop" ? "" : "  (imports + spine under my-whoop)")")
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        let nowSec = Int(Date().timeIntervalSince1970)
        var seen = Set<String>()
        let ids = [did, "my-whoop", "\(did)-noop", "my-whoop-noop",
                   "activity-file", "lifting", "apple-health", "health-connect"].filter { seen.insert($0).inserted }
        var parts: [String] = []
        var latestTs = -1
        var latestDesc = ""
        for id in ids {
            let rows = (try? await store.workouts(deviceId: id, from: 0, to: nowSec, limit: 100_000)) ?? []
            parts.append("\(id)=\(rows.count)")
            if let m = rows.max(by: { $0.startTs < $1.startTs }), m.startTs > latestTs {
                latestTs = m.startTs
                latestDesc = "\(dayStamp(m.startTs)) · \(m.sport) (\(m.source))"
            }
        }
        lines.append("Stored: " + parts.joined(separator: "  "))
        lines.append(latestTs >= 0 ? "Latest: \(latestDesc)" : "Latest: none")
        return lines
    }

    /// Daily-data source breakdown + on-device volume: per-source day counts, which metrics are populated
    /// over the recent week on the imported spine, and the raw-row footprint — the same source reconciliation
    /// the workout block gives, for the "no data / no steps / 0% REM" report class. Best-effort.
    @MainActor static func dailyDataLines(repo: Repository) async -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Daily data by source")
        let did = repo.deviceId
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        var seen = Set<String>()
        let ids = [did, "my-whoop", "\(did)-noop", "my-whoop-noop",
                   "apple-health", "health-connect"].filter { seen.insert($0).inserted }
        var parts: [String] = []
        var spine: [DailyMetric] = []
        for id in ids {
            let rows = (try? await store.dailyMetrics(deviceId: id, from: "0000-01-01", to: "9999-12-31")) ?? []
            parts.append("\(id)=\(rows.count)")
            if id == "my-whoop" { spine = rows }
        }
        lines.append("Days: " + parts.joined(separator: "  "))
        let recent = Array(spine.suffix(7))
        if !recent.isEmpty {
            let n = recent.count
            lines.append("Recent \(n)d (my-whoop): "
                + "sleep=\(recent.filter { ($0.totalSleepMin ?? 0) > 0 }.count)/\(n)  "
                + "recovery=\(recent.filter { $0.recovery != nil }.count)/\(n)  "
                + "steps=\(recent.filter { $0.steps != nil }.count)/\(n)  "
                + "kcal=\(recent.filter { $0.activeKcalEst != nil }.count)/\(n)")
        } else {
            lines.append("Recent: no day rows")
        }
        if let dv = await repo.dataVolumeSnapshot() {
            lines.append("Volume: rawRows=\(dv.dbRows)  importedDays=\(dv.importedDays)  workouts=\(dv.workouts)")
        }
        return lines
    }

    /// Alarm state for the debug export: the configured wake + the last arm's sent-vs-strap-reports (#34), so
    /// a "didn't buzz" report shows at a glance whether the strap accepted the time. Reads persisted defaults
    /// (written by BLEManager.armStrapAlarm + the FrameRouter readback); sync + guarded.
    static func alarmLines() -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Alarm")
        let d = UserDefaults.standard
        let on = d.bool(forKey: "behavior.smartAlarmEnabled")
        let mins = (d.object(forKey: "behavior.smartAlarmMinutes") as? Int) ?? 7 * 60
        lines.append("Enabled: \(on ? "yes" : "no") · set \(String(format: "%02d:%02d", mins / 60, mins % 60))")
        if let sent = d.object(forKey: "alarm.lastArmSentEpoch") as? Int {
            var line = "Last arm: sent \(alarmStamp(sent))"
            if let at = d.object(forKey: "alarm.lastArmAt") as? Double {
                line += " · \(relTime(Date().timeIntervalSince1970 - at))"
            }
            if !d.bool(forKey: "alarm.lastArmConnected") { line += " · strap NOT connected (queued)" }
            lines.append(line)
            if let reported = d.object(forKey: "alarm.lastReportedEpoch") as? Int {
                let mismatch = abs(reported - sent) > 120
                lines.append("Strap reports: \(alarmStamp(reported))"
                    + (mismatch ? "  ⚠️ MISMATCH — strap didn't accept the time" : "  ✓ matches"))
            } else {
                lines.append("Strap reports: (no readback)")
            }
        } else {
            lines.append("Last arm: never")
        }
        return lines
    }

    private static func alarmStamp(_ epochSec: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }

    // MARK: - Formatting helpers

    private static func relTime(_ deltaSec: Double) -> String {
        if deltaSec < 60 { return "just now" }
        let min = Int(deltaSec / 60)
        switch true {
        case min < 60:   return "\(min)m ago"
        case min < 1440: return "\(min / 60)h \(min % 60)m ago"
        default:         return "\(min / 1440)d ago"
        }
    }

    private static func tzLine() -> String {
        let tz = TimeZone.current
        let offMin = tz.secondsFromGMT() / 60
        let a = abs(offMin)
        return "\(tz.identifier) (UTC\(offMin >= 0 ? "+" : "-")\(a / 60):\(String(format: "%02d", a % 60)))"
    }

    private static func dayStamp(_ epochSec: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }
}
