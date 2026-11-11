#if os(iOS)
import SwiftUI
import VisionKit
import StrandCore
import StrandImport

/// Scanning a product: the barcode on the phone (VisionKit), then the wearer's own foods, the downloaded packs,
/// Open Food Facts online when allowed, and otherwise the nutrition label in a form the wearer checks.
struct FoodScanView: View {
    let found: (FoodItem) -> Void

    enum Stage: Equatable { case scanning, looking(String), label(String?) }

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .scanning
    @State private var manualCode = ""

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .scanning:
                    VStack(spacing: 0) {
                        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                            FoodBarcodeScanner(onCode: lookUp).frame(maxHeight: .infinity)
                        } else {
                            ContentUnavailableView("Scanner not available", systemImage: "barcode.viewfinder",
                                                   description: Text("Type the number under the barcode instead."))
                        }
                        HStack {
                            TextField("Barcode number", text: $manualCode).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            Button("Look up", action: lookUpManual).disabled(manualCode.count < 6)
                        }
                        .padding(16)
                        Button("Enter a label without barcode", action: labelWithoutBarcode).padding(.bottom, 16)
                    }
                case .looking(let code):
                    ProgressView("Looking up \(code)").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .label(let code):
                    FoodLabelForm(barcode: code, saved: found)
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) } }
        }
    }

    private func close() { dismiss() }
    private func lookUpManual() { lookUp(manualCode) }
    private func labelWithoutBarcode() { stage = .label(nil) }

    private func lookUp(_ code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count >= 6, stage == .scanning else { return }
        stage = .looking(digits)
        Task {
            guard let store = await repo.storeHandle() else { return }
            if let item = await FoodLibrary.item(store: store, barcode: digits) { found(item); return }
            if FoodProductDataPrefs.looksUpOnline,
               let online = try? await FoodOnline.product(barcode: digits, language: FoodProductDataPrefs.language) {
                found(await FoodLibrary.preferKept(store: store, [online]).first ?? online)
                return
            }
            stage = .label(digits)
        }
    }
}
#endif
