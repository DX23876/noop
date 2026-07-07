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
