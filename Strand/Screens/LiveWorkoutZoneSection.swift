import SwiftUI
import StrandDesign
import StrandAnalytics

/// The five heart-rate zones as plain bars: the current one lights up in its colour, the others stay faint,
/// and under each bar the time this workout has spent in that zone so far. A chosen target zone gets a small
/// marker above its bar rather than a frame around it.
struct LiveWorkoutZoneSection: View {
    let zone: Int
    let targetZone: Int?
    let zoneSet: HRZoneSet
    let timeInZone: TimeInZone
    /// Target-zone coaching line ("In target zone"), nil without a target.
    let coachStatus: String?
    var recordedSeconds: [Double]? = nil

    private var seconds: [Double] {
        if let recordedSeconds, recordedSeconds.count == 5 { return recordedSeconds }
        return (1...5).map { timeInZone.seconds(inZone: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Heart rate zones")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textSecondary)

            HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                ForEach(1...5, id: \.self) { number in
                    LiveWorkoutZoneBar(number: number,
                                       isCurrent: number == zone,
                                       isTarget: number == targetZone,
                                       seconds: Int(seconds[number - 1]),
                                       share: seconds[number - 1] / max(1, seconds.reduce(0, +)))
                }
            }

            if let targetZone, let coachStatus {
                Label {
                    Text("Target zone \(targetZone) · \(coachStatus)")
                } icon: {
                    Image(systemName: "scope")
                }
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.accent)
            }
            if let band = zoneSet.zones.first(where: { $0.number == zone }) {
                Text("Zone \(zone): \(Int(band.lower))-\(Int(band.upper)) bpm (\(Int(band.lowerPct * 100))-\(Int(band.upperPct * 100))% max HR)")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}
