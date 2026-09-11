import SwiftUI
import StrandDesign
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Progress photos
//
// A progress photo is worth nothing on its own and a great deal against another one — but only if the
// two were taken the same way. Distance, stance, lens height and time of day move a body's appearance
// further than a month of training does, which is why the capture screen draws a fixed frame to stand
// in and why each shot is filed under a pose rather than as a loose image.
//
// The comparison is the feature. Two dates side by side at the same size, with the frame that both
// were taken in still implied by the crop.
//
// Everything here stays on the device: files sit in Application Support, are excluded from device
// backup, are re-encoded to strip camera metadata (including location), and never touch the photo
// library or a `.noopbak`. See `ProgressPhotoStore`.

struct BodyPhotosView: View {
    @State private var pose: PhotoPose = .front
    @State private var photos: [ProgressPhoto] = []
    @State private var capturing = false
    @State private var pendingDeletion: ProgressPhoto?
    @State private var leftIndex = 0
    @State private var rightIndex = 0

    private var series: [ProgressPhoto] { photos.filter { $0.pose == pose }
        .sorted { $0.takenAt < $1.takenAt } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Picker("Pose", selection: $pose) {
                    ForEach(PhotoPose.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChangeCompat(of: pose) { _ in resetSelection() }

                if series.isEmpty { emptyCard } else { comparisonCard; timelineCard }
                captureCard
                privacyCard
            }
            .padding(NoopMetrics.gap)
        }
        .navigationTitle("Photos")
        .task { reload() }
        #if os(iOS)
        .fullScreenCover(isPresented: $capturing) {
            PhotoCaptureView(pose: pose) { image in
                if let image { ProgressPhotoStore.save(image, pose: pose) }
                reload()
            }
        }
        #endif
        .confirmationDialog(
            pendingDeletion.map { String(localized: "Delete the \($0.pose.label.lowercased()) photo from \($0.day)?") } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let photo = pendingDeletion { ProgressPhotoStore.delete(photo) }
                    pendingDeletion = nil
                    reload()
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("The file is removed from this device. There is no copy anywhere else.")
            }
    }

    // MARK: - Cards

    private var emptyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("No \(pose.label.lowercased()) photos yet.")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                // The pose guidance is not repeated here: the capture card directly below carries it,
                // next to the button it is guidance for.
            }
        }
    }

    /// Two shots at one size. The whole point of the feature, so it sits above the timeline rather than
    /// behind a tap.
    private var comparisonCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionHeader("Then and now", overline: LocalizedStringKey(pose.label))
                HStack(spacing: 8) {
                    photoPane(index: $leftIndex)
                    photoPane(index: $rightIndex)
                }
                if series.count < 2 {
                    Text("A second photo in this pose gives you something to compare against.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private func photoPane(index: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            #if canImport(UIKit)
            if series.indices.contains(index.wrappedValue),
               let image = ProgressPhotoStore.image(for: series[index.wrappedValue]) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius))
            } else {
                RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius)
                    .fill(StrandPalette.hairline)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            }
            #endif
            if series.count > 1 {
                Picker("", selection: index) {
                    ForEach(Array(series.enumerated()), id: \.offset) { offset, photo in
                        Text(photo.day).tag(offset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else if series.indices.contains(index.wrappedValue) {
                Text(series[index.wrappedValue].day)
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var timelineCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionHeader("Every shot", overline: LocalizedStringKey("\(series.count)"))
                ForEach(series.reversed()) { photo in
                    HStack {
                        Text(photo.day).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button(role: .destructive) { pendingDeletion = photo } label: {
                            Image(systemName: "trash").foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete this photo")
                    }
                }
            }
        }
    }

    private var captureCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(pose.guidance)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                Button { capturing = true } label: {
                    Label(hasToday ? "Retake today's photo" : "Take a photo",
                          systemImage: "camera.fill")
                        .font(StrandFont.subhead)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.metricCyan)
                if hasToday {
                    Text("A new shot replaces today's — one photo per pose per day, so the timeline stays a timeline.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #else
                Text("Photos are taken on iPhone. The ones already stored appear here.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                #endif
            }
        }
    }

    private var privacyCard: some View {
        NoopCard {
            Text("These stay on this device. They are not written to your photo library, not included in a NOOP backup, and excluded from iCloud device backup. Camera metadata, including location, is stripped when the photo is saved.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasToday: Bool {
        series.contains { $0.day == Repository.localDayKey(Date()) }
    }

    private func reload() {
        photos = ProgressPhotoStore.all
        resetSelection()
    }

    /// Opens on the oldest against the newest — the comparison people actually want, rather than two
    /// adjacent weeks that look identical.
    private func resetSelection() {
        leftIndex = 0
        rightIndex = max(series.count - 1, 0)
    }
}
