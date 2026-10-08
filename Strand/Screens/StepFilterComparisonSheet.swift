import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol

/// Experimental side-by-side view of the current WHOOP 5/MG step count and `GaitGatedStepCounter`.
///
/// Presented from Settings → Profile once the experimental toggle is on. It recomputes both counts per
/// calendar day from the stored counter samples and never writes anything, so the daily step total,
/// Energy and every score stay on the current counter. Phone steps come from Apple Health's hourly
/// buckets and are shown for orientation only: the phone counts only while it is carried.
struct StepFilterComparisonSheet: View {
    /// `@AppStorage` key of the Settings toggle that reveals this comparison.
    static let enabledKey = "steps.gaitFilterComparison"
    /// Calendar days shown, today included.
    static let dayCount = 14
    /// Samples read past each day edge so bouts crossing midnight and nearby walking are judged whole.
    static let edgeMarginSeconds = 600

    let repo: Repository
    let onClose: () -> Void
    @EnvironmentObject var profile: ProfileStore

    @State private var rows: [Row] = []
    @State private var loading = true

    struct Row: Identifiable {
        let date: Date
        let current: Int
        let filtered: Int
        let phone: Int?
        let addedStartSteps: Int
        let removedSteps: Int
        var id: Date { date }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    explainerCard
                    if !rows.isEmpty { summaryCard }
                    tableCard
                }
                .padding(20)
            }
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await load() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STEPS · EXPERIMENTAL").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Step filter comparison").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Current count next to the new filter").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done").frame(minWidth: 120)
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(NoopMetrics.space4)
    }

    // MARK: Cards

    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("What the new filter does", systemImage: "figure.walk.motion")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                bullet("A stretch of 60 steps or more counts in full.")
                bullet("Shorter bursts count only when a longer stretch of walking is within three minutes. Arm movement at home mostly produces isolated bursts.")
                bullet("The first steps of each walk, which the strap releases in one go, are added back. The current count drops them.")
                Text("Your step count does not change. This screen only shows what the filter would count.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•").foregroundStyle(StrandPalette.textTertiary)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryCard: some View {
        let measured = rows.filter { $0.current > 0 }
        let n = max(measured.count, 1)
        let current = measured.reduce(0) { $0 + $1.current } / n
        let filtered = measured.reduce(0) { $0 + $1.filtered } / n
        let added = measured.reduce(0) { $0 + $1.addedStartSteps } / n
        let removed = measured.reduce(0) { $0 + $1.removedSteps } / n
        let change = current > 0 ? Double(filtered - current) / Double(current) * 100 : 0
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Average per day").strandOverline()
                statLine(String(localized: "Current count"), Self.grouped(current))
                statLine(String(localized: "New filter"),
                         "\(Self.grouped(filtered)) (\(UnitFormatter.signedPercent(change)))")
                statLine(String(localized: "First steps added"), "+\(Self.grouped(added))")
                statLine(String(localized: "Isolated bursts removed"), "−\(Self.grouped(removed))")
            }
        }
    }

    private var tableCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("By day").strandOverline()
                if rows.isEmpty && !loading {
                    Text("No step data from a WHOOP 5.0 or MG in the last 14 days.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        columnHeader("Day").frame(maxWidth: .infinity, alignment: .leading)
                        columnHeader("Current").frame(width: 64, alignment: .trailing)
                        columnHeader("New").frame(width: 64, alignment: .trailing)
                        columnHeader("Phone").frame(width: 64, alignment: .trailing)
                    }
                    ForEach(rows) { row in
                        HStack {
                            Text(Self.shortDay(row.date))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.grouped(row.current))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Self.grouped(row.filtered))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.accent)
                                .frame(width: 64, alignment: .trailing)
                            Text(row.phone.map(Self.grouped) ?? "–")
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(row))
                    }
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    Text("Calendar days from midnight to midnight, so today can differ slightly from the number on Today. The phone only counts while you carry it.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func columnHeader(_ title: LocalizedStringKey) -> some View {
        Text(title).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 12)
            Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func accessibilityLabel(_ row: Row) -> String {
        let day = Self.shortDay(row.date)
        if let phone = row.phone {
            return String(localized: "\(day): current \(row.current) steps, new filter \(row.filtered) steps, phone \(phone) steps")
        }
        return String(localized: "\(day): current \(row.current) steps, new filter \(row.filtered) steps")
    }

    // MARK: Data

    /// Newest day first, one day at a time so the table fills in while older days are still being read.
    private func load() async {
        loading = true
        defer { loading = false }
        let calendar = Calendar.current
        let scale = max(profile.stepTicksPerStep, 0.5)
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<Self.dayCount {
            if Task.isCancelled { return }
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let from = Int(dayStart.timeIntervalSince1970)
            let to = Int(dayEnd.timeIntervalSince1970)
            let samples = await repo.stepSamplesFromBusiestSource(
                from: from - Self.edgeMarginSeconds, to: to + Self.edgeMarginSeconds - 1)
            guard samples.count > 1 else { continue }
            let result = await Task.detached(priority: .userInitiated) {
                GaitGatedStepCounter.count(samples, windowStart: from, windowEndExclusive: to)
            }.value
            guard result.legacyTicks > 0 || result.totalTicks > 0 else { continue }
            let phone = await repo.appleStepTotal(from: from, toExclusive: to)
            let steps: (Int) -> Int = { Int((Double($0) / scale).rounded()) }
            rows.append(Row(date: dayStart, current: steps(result.legacyTicks), filtered: steps(result.totalTicks),
                            phone: phone, addedStartSteps: steps(result.startBurstTicks),
                            removedSteps: steps(result.rejectedTicks)))
        }
    }

    // MARK: Formatting

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func shortDay(_ date: Date) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: date)
    }
}
