import Foundation

#if canImport(Vision)
import Vision
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// On-device OCR for a user-selected report photo. The recognised text follows the same narrow,
/// review-required parser as a text PDF. No image, OCR text, file name or path is persisted.
enum LabReportImageTextExtractor {
    enum ExtractionError: LocalizedError {
        case unreadable
        case tooLarge
        case noText

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This image couldn't be opened on this device."
            case .tooLarge: return "This image is too large to read locally."
            case .noText: return "No readable text was found in this image."
            }
        }
    }

    static let maxPixels = 24_000_000

    static func text(from url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        let image = try cgImage(from: data)
        guard image.width * image.height <= maxPixels else { throw ExtractionError.tooLarge }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionError.noText }
        return text
    }

    private static func cgImage(from data: Data) throws -> CGImage {
        #if os(iOS)
        guard let image = UIImage(data: data)?.cgImage else { throw ExtractionError.unreadable }
        return image
        #elseif os(macOS)
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ExtractionError.unreadable }
        return cgImage
        #else
        throw ExtractionError.unreadable
        #endif
    }
}
#endif
