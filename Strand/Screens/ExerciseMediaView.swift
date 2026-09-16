import SwiftUI
import AVKit
import ImageIO
import StrandDesign

/// Shows one exercise medium as what it actually is: an animation plays, a video plays, an image is
/// shown. A quiet-motion state holds the first frame instead of animating, and a file that cannot be
/// decoded falls back to the still presentation rather than blocking the screen.
///
/// The frame clock is gated on the same `NoopMotionState` every other never-settling animation uses,
/// not on Reduce Motion alone: a per-frame decode is exactly the work Low Power Mode and the in-app
/// quiet-motion preference exist to stop. Nothing is hidden when it poses still — the first frame
/// stays on screen, and the instructions beside it carry the same information.
struct ExerciseMediaView: View {
    let media: ExerciseMedia
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius))
    }

    @ViewBuilder private var content: some View {
        switch media.kind {
        case .video:
            ExerciseMediaVideo(url: media.url, autoplay: !poseStill)
        case .animation:
            AnimatedExerciseImage(url: media.url, animates: !poseStill)
        case .image:
            AsyncImage(url: media.url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
            }
        }
    }
}

/// Frame-by-frame playback of an animated image. Frames and their durations are decoded once off the
/// main thread; the timeline then picks the frame for the elapsed time, so there is no per-frame state.
private struct AnimatedExerciseImage: View {
    let url: URL
    let animates: Bool
    @State private var frames: [AnimatedImageFrame] = []
    @State private var totalDuration: Double = 0
    @State private var failed = false

    var body: some View {
        Group {
            if failed || frames.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
            } else if animates, totalDuration > 0 {
                TimelineView(.animation) { context in
                    frame(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                Image(decorative: frames[0].image, scale: 1).resizable().scaledToFit()
            }
        }
        .task(id: url) { await load() }
    }

    private func frame(at time: TimeInterval) -> some View {
        let offset = time.truncatingRemainder(dividingBy: totalDuration)
        var elapsed = 0.0
        var current = frames[0]
        for candidate in frames {
            elapsed += candidate.duration
            if offset < elapsed { current = candidate; break }
        }
        return Image(decorative: current.image, scale: 1).resizable().scaledToFit()
    }

    private func load() async {
        let decoded = await Task.detached(priority: .userInitiated) {
            AnimatedImageFrame.decode(url: url)
        }.value
        frames = decoded
        totalDuration = decoded.reduce(0) { $0 + $1.duration }
        failed = decoded.isEmpty
    }
}

private struct AnimatedImageFrame: Sendable {
    let image: CGImage
    let duration: Double

    /// Reads the frames of an animated image with their own delays. A still image decodes to a single
    /// frame, which is exactly the fallback presentation.
    static func decode(url: URL) -> [AnimatedImageFrame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            return AnimatedImageFrame(image: image, duration: delay(source, index))
        }
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else { return 0.1 }
        let container = (properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            ?? (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
        let unclamped = container?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = container?[kCGImagePropertyGIFDelayTime] as? Double
        let value = unclamped ?? clamped ?? 0.1
        // Browsers and viewers treat a zero or near-zero delay as 100 ms; matching that keeps a pack's
        // animations from running at hundreds of frames a second.
        return value < 0.011 ? 0.1 : value
    }
}

/// A looping, muted demonstration clip. It carries no sound and no controls when it plays on its own.
private struct ExerciseMediaVideo: View {
    let url: URL
    let autoplay: Bool
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .disabled(autoplay)
            .task(id: url) { prepare() }
            .onDisappear { player?.pause() }
    }

    private func prepare() {
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { _ in
            player.seek(to: .zero)
            if autoplay { player.play() }
        }
        if autoplay { player.play() }
    }
}
