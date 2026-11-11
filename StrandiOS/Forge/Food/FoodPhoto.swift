#if os(iOS)
import UIKit

/// A photo made small enough to send or read: longest side 1,280 points, upright, JPEG.
enum FoodPhoto {
    static func jpeg(_ image: UIImage, longestSide: Double = 1_280, quality: Double = 0.7) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, longestSide / max(1, longest))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return (image.preparingThumbnail(of: size) ?? image).jpegData(compressionQuality: quality)
    }
}
#endif
