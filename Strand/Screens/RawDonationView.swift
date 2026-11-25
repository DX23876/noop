import SwiftUI
import StrandCore
import StrandDesign

// RawDonationView.swift — "Help teach the app", the page where someone can let NOOP record short
// windows of raw motion during a workout and send them so a sport detector can be built.
//
// The page explains before it asks: the ticks sit under the text, nothing is ticked by default, and the
// send is a separate press on a recording that is already finished. Without a service address in the
// feed there is no send at all and the page says so instead of offering a button that cannot work.
//
// The wording is held to what can be shown: no claim that nobody could ever be identified from motion,
// because that is not provable, and the open hardware question is stated rather than glossed.

struct RawDonationView: View {
    @ObservedObject private var recorder = RawDonationRecorder.shared
    @State private var settings = RawDonationSettings.standard
    @State private var sending: String?
    @State private var failed: String?
    /// The recording about to be deleted. Deleting one throws away a workout's worth of motion that
    /// cannot be recorded again, and it sat as a single tap beside Send, in the quietest colour of
    /// the three. Withdrawing a report asks first for the same reason.
    @State private var deleting: PendingDonation?
    @State private var revision = 0

    /// The sports a strap-worn recording is actually useful for: the arm repeats a cadence a detector
    /// could learn. Every name here is spelled as `WorkoutCatalog` spells it, because the recorder
    /// matches a running workout against these by `WorkoutSource.sportKey`, and a name the catalogue
    /// does not know would simply never match.
    ///
    /// Strength is left out on purpose, and stays out: the arm moves differently in every exercise,
    /// so a set of curls looks like nothing else and teaches a detector nothing.
    private static let outdoorSports = ["Walking", "Nordic walking", "Hiking", "Running", "Rucking",
                                        "Cycling", "Mountain biking", "Rowing"]

    /// Indoors matters more than it looks: there is no GPS to fall back on, so how the arm moves is the
    /// only thing that could tell a treadmill from a bike from a rowing machine.
    private static let indoorSports = ["Treadmill walk", "Treadmill run", "Indoor cycle", "Spinning",
                                       "Elliptical", "Row machine", "Stair climber", "Jump rope",
                                       "Pool swim"]

    /// The service address, read from the same cached feed the Roadmap page uses. No address means no
    /// send button at all, rather than one that fails.
    @State private var service: URL?

    var body: some View {
        ScreenScaffold(title: "Help teach the app",
                       subtitle: "Short recordings of how you move, so NOOP can learn to spot a workout") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ProjectScene(name: "scene_helping")
                explainer
                sportsCard
                recordingsCard
                caveat
            }
        }
        .task {
            service = await ProjectPageStore(directory: RoadmapModel.cacheDirectory).forWriting().service
        }
        .confirmationDialog("Delete this recording?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let donation = deleting { recorder.forget(donation) }
                deleting = nil
            }
            Button("Keep it", role: .cancel) { deleting = nil }
        } message: {
            Text("The motion in it is gone, and that workout cannot be recorded again.")
        }
    }

    // MARK: Explainer

    private var explainer: some View {
        ForgeListGroup("What this is") {
            Text("A hundred times a second, the strap measures how your arm moves in six directions. During a workout you ticked, NOOP records three stretches of two minutes of that, and nothing else.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(StrandPalette.hairline)
            Text("What is not in it")
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Label("No name and no mail address", systemImage: "xmark")
                Label("No device identifier", systemImage: "xmark")
                Label("No location and no route", systemImage: "xmark")
                Label("No heart data", systemImage: "xmark")
                Label("Times counted from the start of the recording, not the time of day", systemImage: "xmark")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            Text("Nothing is stored that could tie a recording to a person.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(StrandPalette.hairline)
            Text("What it is for")
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            Text("Teaching the app to tell walking from cycling on its own, so a workout no longer has to be started by hand. The manufacturer put millions into labs for this. There are no labs here. There are people who share their recordings.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A detector built from this works for everyone, including people who sent nothing. Nobody promises when, or whether, it arrives. Recordings are kept for 24 months.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Ticks

    private var sportsCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            ForgeListGroup("Outdoors",
                           note: "Nothing is ticked to begin with. A recording still waits for you to send it.") {
                sportToggles(Self.outdoorSports)
            }
            ForgeListGroup("Indoors",
                           note: "The most useful of the lot: indoors there is no GPS, so how your arm moves is all there is to go on.") {
                sportToggles(Self.indoorSports)
            }
            ForgeListGroup {
                ForgeToggleRow(title: "Keep my own copy after sending",
                               subtitle: "Raw motion is the heaviest thing NOOP can store",
                               isOn: Binding(get: { _ = revision; return settings.keepsLocalCopy },
                                             set: { settings.keepsLocalCopy = $0; revision += 1 }))
            }
        }
    }

    @ViewBuilder
    private func sportToggles(_ sports: [String]) -> some View {
        ForEach(sports, id: \.self) { sport in
            ForgeToggleRow(title: LocalizedStringKey(sport), isOn: Binding(
                get: { _ = revision; return settings.isOn(sport) },
                set: { settings.set(sport, on: $0); revision += 1 }
            ))
        }
    }

    // MARK: Recordings

    @ViewBuilder
    private var recordingsCard: some View {
        if recorder.pending.isEmpty {
            ForgeListGroup("Your recordings") {
                Text("Nothing recorded yet. Tick a sport, then wear the strap through a workout.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForgeListGroup("Your recordings",
                           note: service == nil
                               ? "Sending is not set up yet. The recordings stay on your phone until it is."
                               : "Quote the code if you ever want one deleted again.") {
                ForEach(recorder.pending) { donation in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "\(donation.code) · \(donation.sport)")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(Self.summary(donation))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        HStack(spacing: NoopMetrics.space3) {
                            if donation.sentAt != nil {
                                Text("Sent").font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.statusPositive)
                            } else if service != nil {
                                Button("Send") { Task { await send(donation) } }
                                    .buttonStyle(.plain)
                                    .font(StrandFont.subhead.weight(.semibold))
                                    .foregroundStyle(StrandPalette.accent)
                                    .disabled(sending != nil)
                            }
                            Button("Delete", role: .destructive) { deleting = donation }
                                .buttonStyle(.plain)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.statusCritical)
                            Spacer(minLength: 0)
                            if sending == donation.id {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if failed == donation.id {
                            Text("That did not go out. Try again later.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var caveat: some View {
        Text("Recording raw motion during a workout has not been measured against live heart rate and history sync yet. If something behaves oddly while it records, that is worth a bug report.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.statusWarning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func send(_ donation: PendingDonation) async {
        sending = donation.id
        failed = nil
        let payload = await recorder.payload(for: donation)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let metadata = RawDonationPackage.metadata(for: donation, appVersion: version)
        let outcome = await RawDonationUploader(service: service)
            .send(donation: donation, payload: payload, metadata: metadata)
        sending = nil
        if outcome == .sent {
            recorder.markSent(donation)
        } else {
            failed = donation.id
        }
    }

    static func summary(_ donation: PendingDonation) -> String {
        let minutes = max(1, donation.recordedSeconds / 60)
        let kilobytes = max(1, donation.bytes / 1000)
        return String(localized: "\(minutes) min recorded, about \(kilobytes) kB")
    }
}
