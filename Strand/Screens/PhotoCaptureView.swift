#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Standing in the same place, twice
//
// The frame is the point of this screen. Two photos taken a month apart differ by stance, distance,
// lens height and time of day far more than by any training that happened between them — so an
// unguided pair of photos mostly measures how the photos were taken. A fixed outline to stand inside
// removes most of that in one step, and it has to be visible AT CAPTURE, not offered as advice
// afterwards.
//
// `UIImagePickerController` with a `cameraOverlayView` rather than a hand-built AVCapture session: the
// system camera already handles orientation, focus, the volume-button shutter and every device's lens
// arrangement, and reimplementing that to draw one rectangle would be a large amount of code whose
// only new behaviour is the rectangle.

struct PhotoCaptureView: UIViewControllerRepresentable {
    let pose: PhotoPose
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraDevice = .front
            picker.showsCameraControls = true
            picker.cameraOverlayView = Self.overlay(for: pose, in: UIScreen.main.bounds)
        } else {
            // The simulator, and any device whose camera is unavailable. The library is a fallback so
            // the flow can still be walked; the frame guidance is lost, and the sheet says so.
            picker.sourceType = .photoLibrary
        }
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    /// A body-shaped outline plus horizon lines, drawn over the live preview.
    ///
    /// Deliberately not a silhouette anyone has to match exactly — it is a placement guide, and a
    /// figure that implied "stand like this person" would be its own kind of unpleasant. It marks where
    /// the head and feet should sit and where the frame's centre is, which is all that repeatability
    /// needs.
    private static func overlay(for pose: PhotoPose, in bounds: CGRect) -> UIView {
        let view = UIView(frame: bounds)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        // Inside the camera's preview, not the screen — see `previewRect`.
        let preview = previewRect(in: bounds)
        let inset = bounds.width * 0.18
        let top = preview.minY + preview.height * 0.16   // leaves room above the head mark for the hint
        let bottom = preview.maxY - preview.height * 0.04
        let frame = CGRect(x: inset, y: top, width: bounds.width - inset * 2, height: bottom - top)

        let outline = CAShapeLayer()
        outline.path = UIBezierPath(roundedRect: frame, cornerRadius: 18).cgPath
        outline.strokeColor = UIColor.white.withAlphaComponent(0.75).cgColor
        outline.fillColor = UIColor.clear.cgColor
        outline.lineWidth = 2
        outline.lineDashPattern = [8, 6]
        view.layer.addSublayer(outline)

        // Head and feet marks: the two points that actually have to land in the same place for two
        // photos to be comparable.
        for y in [frame.minY, frame.maxY] {
            let mark = CAShapeLayer()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: frame.minX - 14, y: y))
            path.addLine(to: CGPoint(x: frame.minX + 22, y: y))
            path.move(to: CGPoint(x: frame.maxX - 22, y: y))
            path.addLine(to: CGPoint(x: frame.maxX + 14, y: y))
            mark.path = path.cgPath
            mark.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
            mark.lineWidth = 2
            view.layer.addSublayer(mark)
        }

        let centre = CAShapeLayer()
        let centrePath = UIBezierPath()
        centrePath.move(to: CGPoint(x: frame.midX, y: frame.minY + 8))
        centrePath.addLine(to: CGPoint(x: frame.midX, y: frame.maxY - 8))
        centre.path = centrePath.cgPath
        centre.strokeColor = UIColor.white.withAlphaComponent(0.28).cgColor
        centre.lineWidth = 1
        centre.lineDashPattern = [4, 8]
        view.layer.addSublayer(centre)

        let hint = UILabel(frame: CGRect(x: 16, y: top - 54, width: bounds.width - 32, height: 44))
        hint.text = pose.guidance
        hint.numberOfLines = 2
        hint.textAlignment = .center
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.shadowColor = .black
        hint.shadowOffset = CGSize(width: 0, height: 1)
        view.addSubview(hint)

        return view
    }

    /// Where the system camera draws its 4:3 preview, in the overlay's own coordinates — which are the
    /// picker's, not the screen's: SwiftUI lays the picker out inside the safe area, and the camera puts
    /// a 32 pt control bar above the preview and the shutter below it. An outline laid out against the
    /// full screen height put the feet mark in the black control area, outside the photo it was meant to
    /// frame (seen on an iPhone 17 Pro under iOS 27: a 402 × 536 pt preview 32 pt below the picker's
    /// top). The system does not publish this rect, so it is derived from the sensor's 4:3 aspect rather
    /// than guessed as a fraction of the screen height.
    private static func previewRect(in bounds: CGRect) -> CGRect {
        let height = min(bounds.width * 4 / 3, bounds.height)
        return CGRect(x: bounds.minX, y: 32, width: bounds.width, height: height)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
            picker.dismiss(animated: true)
        }
    }
}
#endif
