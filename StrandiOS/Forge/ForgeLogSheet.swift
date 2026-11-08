#if os(iOS)
import SwiftUI
import PhotosUI
import StrandDesign
import StrandAnalytics

/// What the redesign's Log sheet can open. The shell maps each to a screen that already exists, so the
/// sheet only gathers the entry points that were spread over the quick-action menu, Today and More.
enum ForgeLogChoice: Hashable {
    case coachWrite, coachSpeak
    /// A photo for the coach to read (PNG, base64), when the provider can read one.
    case coachPhoto(String)
    case workout, weight, journal, drink, energy, sleep, labMarkers, breathe, liveHeartRate
}

/// The redesign's "Log" sheet: logging through the coach first (when it is on), then the direct forms.
struct ForgeLogSheet: View {
    let onPick: (ForgeLogChoice) -> Void
    /// Whether the coach's provider can read a photo; the Photo button only shows when it can.
    var acceptsPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

    private struct Item: Identifiable {
        let choice: ForgeLogChoice
        let title: String
        let systemImage: String
        /// The entry's own colour, as the measure it logs is drawn elsewhere in the app.
        var tint: Color = ForgeColor.accent
        var id: String { title }
    }

    /// The prototype's order. Blood pressure and biomarkers open the lab book (blood pressure is one of its
    /// paired markers); mood and medication open the journal, where both are logged.
    private var direct: [Item] {
        [
            Item(choice: .workout, title: String(localized: "Add workout"), systemImage: "figure.walk", tint: ForgeColor.effort),
            Item(choice: .weight, title: String(localized: "Weight"), systemImage: "figure.stand", tint: .pink),
            Item(choice: .journal, title: String(localized: "Journal"), systemImage: "book.fill", tint: .brown),
            Item(choice: .drink, title: String(localized: "Drink"), systemImage: "drop.fill", tint: StrandPalette.metricCyan),
            Item(choice: .energy, title: String(localized: "Food"), systemImage: "fork.knife", tint: .orange),
            Item(choice: .sleep, title: String(localized: "Sleep"), systemImage: "moon.fill", tint: ForgeColor.rest),
            Item(choice: .labMarkers, title: String(localized: "Blood pressure"), systemImage: "drop.fill", tint: .red),
            Item(choice: .journal, title: String(localized: "Mood"), systemImage: "face.smiling.inverse", tint: .yellow),
            Item(choice: .labMarkers, title: String(localized: "Health records"), systemImage: "flask.fill", tint: .purple),
            Item(choice: .journal, title: String(localized: "Medication"), systemImage: "cross.case.fill", tint: .mint),
            Item(choice: .breathe, title: String(localized: "Breathe"), systemImage: "wind", tint: .teal),
            Item(choice: .liveHeartRate, title: String(localized: "Live heart rate"), systemImage: "heart.fill", tint: StrandPalette.metricRose),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if coachFeatureEnabled {
                    Text("Log with the coach").font(ForgeFont.section).foregroundStyle(ForgeColor.text).legibleOnPhoto()
                    HStack(spacing: 0) {
                        coachButton(.coachWrite, "Write", "bubble.left.fill")
                        coachButton(.coachSpeak, "Speak", "mic.fill")
                        if acceptsPhotos {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                coachIcon("Photo", "camera.fill")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Rectangle().fill(ForgeColor.separator).frame(height: 0.5).padding(.vertical, 2)
                }
                Text("Log yourself").font(ForgeFont.section).foregroundStyle(ForgeColor.text).legibleOnPhoto()
                FlowRows(spacing: 8) {
                    ForEach(direct) { item in
                        Button { onPick(item.choice) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.systemImage)
                                    .font(.system(.subheadline, weight: .semibold))
                                    .foregroundStyle(item.tint)
                                Text(item.title)
                                    .font(.system(.callout, weight: .medium))
                                    .foregroundStyle(ForgeColor.text)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .background(Capsule().fill(ForgeColor.fill))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .padding(.top, 8)
        }
        .background(ForgeColor.canvas.ignoresSafeArea())
        .onChange(of: photoItem) { _, item in
            Task { await handlePhoto(item) }
        }
    }

    private func coachButton(_ choice: ForgeLogChoice, _ title: LocalizedStringKey, _ image: String) -> some View {
        Button { onPick(choice) } label: { coachIcon(title, image) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
    }

    private func coachIcon(_ title: LocalizedStringKey, _ image: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: image)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(ForgeColor.accent)
                .frame(width: 60, height: 60)
                .background(Circle().fill(ForgeColor.fill))
            Text(title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
        }
    }

    /// Scales the picked photo down (long side 1024 pt) before it is encoded, so a full-resolution image
    /// is never sent.
    private func handlePhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let longSide = max(image.size.width, image.size.height)
        let scale = min(1, 1024 / max(longSide, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = scaled.pngData() else { return }
        photoItem = nil
        onPick(.coachPhoto(png.base64EncodedString()))
    }
}

/// Lays chips out left to right and wraps them onto further rows.
struct FlowRows: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
