import Foundation

#if canImport(PDFKit)
import PDFKit

/// Reads only embedded text from a local PDF. It never uploads the file, keeps no copy, and makes no
/// attempt to interpret medical meaning; `LabReportTextImport` turns the text into review candidates.
enum LabReportPDFTextExtractor {
    enum ExtractionError: LocalizedError {
        case unreadable
        case tooManyPages
        case noSelectableText

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This PDF couldn't be opened on this device."
            case .tooManyPages: return "This PDF has too many pages to review locally."
            case .noSelectableText: return "This PDF has no selectable text. Add the readings manually for now."
            }
        }
    }

    static let maxPages = 40

    static func text(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable }
        guard document.pageCount > 0, document.pageCount <= maxPages else { throw ExtractionError.tooManyPages }
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionError.noSelectableText }
        return text
    }
}
#endif
