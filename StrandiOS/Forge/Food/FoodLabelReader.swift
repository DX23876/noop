#if os(iOS)
import Foundation
import Vision
import StrandImport

/// Reads a nutrition label photo on the phone (Vision), off the main actor, into the shared label parser.
actor FoodLabelReader {
    static let shared = FoodLabelReader()

    func read(_ jpeg: Data) -> NutritionLabelReading? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(data: jpeg, options: [:]).perform([request])) != nil else { return nil }
        return NutritionLabelParser.parse(lines: Self.rows(request.results ?? []))
    }

    /// Pieces of text on the same row joined into one line ("Fett" and "3,1 g"), top to bottom.
    static func rows(_ observations: [VNRecognizedTextObservation]) -> [String] {
        var rows: [(y: Double, parts: [(x: Double, text: String)])] = []
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let box = observation.boundingBox
            if let index = rows.firstIndex(where: { abs($0.y - box.midY) < box.height * 0.6 }) {
                rows[index].parts.append((box.minX, text))
            } else {
                rows.append((box.midY, [(box.minX, text)]))
            }
        }
        return rows.sorted { $0.y > $1.y }.map { $0.parts.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
    }
}
#endif
