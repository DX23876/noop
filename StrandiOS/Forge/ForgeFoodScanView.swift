#if os(iOS)
import SwiftUI
import VisionKit
import Vision
import StrandDesign
import StrandCore
import StrandImport
import WhoopStore

/// Scanning a product: the barcode on the phone (VisionKit), then the wearer's own scanned foods, the downloaded
/// packs, Open Food Facts online when allowed, and otherwise a photo of the nutrition label read on the phone
/// (Vision) into a form the wearer checks. A label read once is kept as their own food with its barcode.
struct ForgeFoodScanView: View {
    let onFound: (FoodItem) -> Void

    enum Stage: Equatable { case scanning, looking(String), label(String?), failed(String) }

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .scanning
    @State private var manualCode = ""
    @State private var showCamera = false
    @State private var reading: NutritionLabelReading?

    private var canLookOnline: Bool {
        FoodProductDataPrefs.mode == .online
            || (FoodProductDataPrefs.mode == .packs && UserDefaults.standard.bool(forKey: FoodProductDataPrefs.unknownBarcodesOnlineKey))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .scanning: scanner
                case .looking(let code):
                    VStack(spacing: 12) { ProgressView(); Text("Looking up \(code)").foregroundStyle(ForgeColor.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .label(let code):
                    ForgeFoodLabelForm(barcode: code, reading: reading, onTakePhoto: { showCamera = true }) { item in
                        onFound(item)
                    }
                case .failed(let message):
                    VStack(spacing: 12) {
                        Text(message).foregroundStyle(ForgeColor.secondary).multilineTextAlignment(.center)
                        Button("Try again") { stage = .scanning }
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Text("Scan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showCamera) {
                ForgeFoodCamera { image in
                    showCamera = false
                    Task { reading = await Self.readLabel(image) }
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var scanner: some View {
        VStack(spacing: 0) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                BarcodeScanner { code in Task { await lookUp(code) } }
                    .frame(maxHeight: .infinity)
            } else {
                Text("The camera scanner is not available here. Type the number under the barcode instead.")
                    .foregroundStyle(ForgeColor.secondary).padding().frame(maxHeight: .infinity)
            }
            HStack {
                TextField("Barcode number", text: $manualCode).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                Button("Look up") { Task { await lookUp(manualCode) } }.disabled(manualCode.count < 6)
            }
            .padding()
            Button("Read a label without barcode") { reading = nil; stage = .label(nil) }
                .padding(.bottom, 16)
        }
    }

    private func lookUp(_ code: String) async {
        let digits = code.filter(\.isNumber)
        guard digits.count >= 6 else { return }
        stage = .looking(digits)
        guard let store = await repo.storeHandle() else { return }
        if let found = await FoodLibrary.item(store: store, barcode: digits) {
            onFound(found)
            return
        }
        if canLookOnline, let online = try? await FoodOnline.product(barcode: digits, language: FoodProductDataPrefs.language) {
            onFound(await FoodLibrary.preferKept(store: store, [online]).first ?? online)
            return
        }
        reading = nil
        stage = .label(digits)
    }

    /// The label's text, row by row, recognised on the phone.
    static func readLabel(_ image: UIImage) async -> NutritionLabelReading? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> NutritionLabelReading? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = false
            guard (try? VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])) != nil else { return nil }
            let observations = request.results ?? []
            return NutritionLabelParser.parse(lines: Self.joinRows(observations))
        }.value
    }

    /// Pieces of text on the same row joined into one line ("Fett" and "3,1 g").
    static func joinRows(_ observations: [VNRecognizedTextObservation]) -> [String] {
        var rows: [(y: CGFloat, parts: [(x: CGFloat, text: String)])] = []
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let y = observation.boundingBox.midY, height = observation.boundingBox.height
            if let index = rows.firstIndex(where: { abs($0.y - y) < height * 0.6 }) {
                rows[index].parts.append((observation.boundingBox.minX, text))
            } else {
                rows.append((y, [(observation.boundingBox.minX, text)]))
            }
        }
        return rows.sorted { $0.y > $1.y }.map { $0.parts.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
    }
}

/// VisionKit's live barcode scanner, reporting the first code it recognises.
private struct BarcodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var reported = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !reported else { return }
            for case let .barcode(code) in items {
                if let value = code.payloadStringValue {
                    reported = true
                    scanner.stopScanning()
                    onCode(value)
                    return
                }
            }
        }
    }
}

/// The camera, for one photo of a label.
struct ForgeFoodCamera: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image.normalisedOrientation()) }
        }
    }
}

private extension UIImage {
    /// Pixels drawn upright, so Vision reads the photo the way it was taken.
    func normalisedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// The label's values in a form: filled from the photo when there is one, every field editable, saved as the
/// wearer's own food (with the barcode, when scanned).
struct ForgeFoodLabelForm: View {
    let barcode: String?
    let reading: NutritionLabelReading?
    let onTakePhoto: () -> Void
    let onSaved: (FoodItem) -> Void

    @EnvironmentObject private var repo: Repository
    @State private var name = ""
    @State private var brand = ""
    @State private var serving: Double?
    @State private var values: [FoodNutrient: Double] = [:]

    private let fields: [(FoodNutrient, String)] = [
        (.energyKcal, String(localized: "Energy (kcal)")), (.fatG, String(localized: "Fat (g)")),
        (.satFatG, String(localized: "Saturated fat (g)")), (.carbsG, String(localized: "Carbs (g)")),
        (.sugarG, String(localized: "Sugar (g)")), (.fiberG, String(localized: "Fibre (g)")),
        (.proteinG, String(localized: "Protein (g)")), (.saltG, String(localized: "Salt (g)")),
    ]

    var body: some View {
        Form {
            Section {
                Button { onTakePhoto() } label: { Label("Photograph the nutrition label", systemImage: "camera") }
            } footer: {
                Text(reading == nil ? String(localized: "The text is read on this iPhone. Check every value before saving.")
                     : String(localized: "Read from the photo. Check every value before saving."))
            }
            Section {
                TextField("Name", text: $name)
                TextField("Brand", text: $brand)
                if let barcode { Text("Barcode \(barcode)").foregroundStyle(ForgeColor.secondary) }
            }
            Section("Per 100 g") {
                ForEach(fields, id: \.0) { nutrient, label in
                    HStack {
                        Text(label)
                        Spacer()
                        TextField("–", value: Binding(get: { values[nutrient] }, set: { values[nutrient] = $0 }),
                                  format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                }
            }
            Section {
                HStack {
                    Text("Portion (g)")
                    Spacer()
                    TextField("–", value: $serving, format: .number).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
            }
            Section {
                Button("Save food") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || !FoodNutrient.macros.allSatisfy { values[$0] != nil })
            }
        }
        .onChange(of: reading) { _, next in apply(next) }
        .onAppear { apply(reading) }
    }

    private func apply(_ reading: NutritionLabelReading?) {
        guard let reading else { return }
        for (key, value) in reading.per100 { if let nutrient = FoodNutrient(rawValue: key) { values[nutrient] = value } }
        if let amount = reading.servingAmount { serving = amount }
    }

    private func save() async {
        guard let store = await repo.storeHandle() else { return }
        var amounts = NutrientAmounts(values)
        if amounts[.sodiumMg] == nil, let salt = amounts[.saltG] { amounts[.sodiumMg] = salt / 2.5 * 1_000 }
        let item = FoodItem(id: "own:new", source: .online, name: name.trimmingCharacters(in: .whitespaces),
                            brand: brand.isEmpty ? nil : brand, servingG: serving, per100g: amounts, barcode: barcode)
        if let saved = await FoodLibrary.saveOwn(store: store, item, origin: .label) { onSaved(saved) }
    }
}
#endif
