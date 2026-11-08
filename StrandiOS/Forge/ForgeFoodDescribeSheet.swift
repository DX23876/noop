#if os(iOS)
import SwiftUI
import PhotosUI
import StrandDesign
import StrandCore

/// Describing or photographing a meal for the coach (decision 2026-11-08). The coach names foods and amounts,
/// the database gives the nutrients, and the wearer checks every line before it goes into the cart.
struct ForgeFoodDescribeSheet: View {
    let onAdd: ([FoodCartLine]) -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var working = false
    @State private var lines: [FoodCartLine] = []
    @State private var unmatched: [String] = []
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("For example: two slices of wholemeal bread with butter and a banana", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                    if coach.readsFoodPhotos {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label(photoData == nil ? "Add a photo" : "Photo added", systemImage: "camera")
                        }
                    }
                    Button {
                        Task { await identify() }
                    } label: {
                        if working { ProgressView() } else { Text("Find the foods") }
                    }
                    .disabled(working || (text.trimmingCharacters(in: .whitespaces).isEmpty && photoData == nil))
                } footer: {
                    Text("Your words and the photo go to your coach's provider. Forge takes the nutrients from its own database. Amounts from a photo are estimates.")
                }
                if failed {
                    Section { Text("The coach did not answer. Try again or add the foods yourself.").foregroundStyle(ForgeColor.secondary) }
                }
                if !lines.isEmpty {
                    Section("Check before adding") {
                        ForEach($lines) { $line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.item.name).font(.system(.callout, weight: .semibold))
                                HStack {
                                    TextField("g", value: $line.grams, format: .number.precision(.fractionLength(0)))
                                        .keyboardType(.numberPad).frame(width: 70)
                                    Text("g").foregroundStyle(ForgeColor.secondary)
                                    Spacer()
                                    Text("\(ForgeFoodModel.kcal(line.totals[.energyKcal])) kcal").foregroundStyle(ForgeColor.secondary)
                                }
                            }
                        }
                        .onDelete { lines.remove(atOffsets: $0) }
                    }
                }
                if !unmatched.isEmpty {
                    Section {
                        ForEach(unmatched, id: \.self) { Text($0) }
                    } header: { Text("Not found") } footer: { Text("Add these yourself with the search.") }
                }
            }
            .navigationTitle(Text("Describe a meal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(lines.filter { $0.grams > 0 }); dismiss() }.disabled(lines.isEmpty)
                }
            }
            .onChange(of: photo) { _, item in
                Task { photoData = try? await item?.loadTransferable(type: Data.self) }
            }
        }
    }

    private func identify() async {
        guard let store = await repo.storeHandle() else { return }
        working = true
        failed = false
        defer { working = false }
        let image = photoData.flatMap { UIImage(data: $0) }.flatMap(Self.jpegBase64)
        guard let result = await coach.foodCart(description: text, imageBase64: image, store: store) else {
            failed = true
            return
        }
        lines = result.lines.map { FoodCartLine(item: $0.item, grams: $0.grams, portionLabel: nil) }
        unmatched = result.unmatched.map { "\($0.name), \(ForgeFoodModel.grams($0.grams)) g" }
    }

    /// A photo small enough for a request: longest side 1,280 points, JPEG.
    static func jpegBase64(_ image: UIImage) -> String? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1_280 / max(1, longest))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.7)?.base64EncodedString()
    }
}
#endif
