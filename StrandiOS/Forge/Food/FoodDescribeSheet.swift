#if os(iOS)
import SwiftUI
import PhotosUI
import StrandCore

/// Describing or photographing a meal for the coach (decision 2026-11-08). The coach names foods and amounts, the
/// database gives the nutrients, and the wearer checks every line before it goes into the cart.
struct FoodDescribeSheet: View {
    let add: ([FoodCartLine]) -> Void

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
                    Button(action: identify) {
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
                            LabeledContent(line.item.name) {
                                HStack(spacing: 4) {
                                    TextField("g", value: $line.grams, format: .number.precision(.fractionLength(0)))
                                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(minWidth: 56)
                                    Text("g · \(FoodText.kcal(line.totals[.energyKcal])) kcal").foregroundStyle(ForgeColor.secondary)
                                }
                            }
                        }
                        .onDelete(perform: removeLines)
                    }
                }
                if !unmatched.isEmpty {
                    Section {
                        ForEach(unmatched, id: \.self) { Text($0) }
                    } header: { Text("Not found") } footer: { Text("Add these yourself with the search.") }
                }
            }
            .navigationTitle("Describe a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: confirm).disabled(lines.isEmpty) }
            }
            .task(id: photo) { photoData = try? await photo?.loadTransferable(type: Data.self) }
        }
    }

    private func cancel() { dismiss() }
    private func confirm() {
        // The photo is kept with the meal (decision 2026-11-08), outside the database and outside backups.
        let kept = photoData.flatMap(UIImage.init(data:)).flatMap { image -> String? in
            guard let photos = FoodPhotoStore.appDefault, let jpeg = FoodPhoto.jpeg(image) else { return nil }
            return photos.save(jpeg: jpeg, preview: FoodPhoto.jpeg(image, longestSide: 480, quality: 0.75))
        }
        add(lines.filter { $0.grams > 0 }.map { line in var line = line; line.photoId = kept; return line })
        dismiss()
    }
    private func removeLines(_ offsets: IndexSet) { lines.remove(atOffsets: offsets) }

    private func identify() {
        working = true
        failed = false
        Task {
            defer { working = false }
            guard let store = await repo.storeHandle() else { return }
            let image = photoData.flatMap(UIImage.init(data:)).flatMap { FoodPhoto.jpeg($0) }?.base64EncodedString()
            guard let result = await coach.foodCart(description: text, imageBase64: image, store: store) else {
                failed = true
                return
            }
            lines = result.lines.map { FoodCartLine(item: $0.item, grams: $0.grams) }
            unmatched = result.unmatched.map { "\($0.name), \(FoodText.grams($0.grams)) g" }
        }
    }
}
#endif
