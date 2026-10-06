import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Speaks the live workout's announcements over whatever is playing: music ducks for the sentence and comes
/// back afterwards. It speaks only into headphones, so nobody is surprised by a voice from the speaker, and it
/// uses the best installed voice for the app's language, falling back to the system default for it.
@MainActor
final class WorkoutSpeaker: NSObject {
    #if os(iOS)
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Headphone-type outputs: wired, Bluetooth and USB. A car or AirPlay speaker is not private.
    private static let privateOutputs: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio,
    ]

    var headphonesConnected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { Self.privateOutputs.contains($0.portType) }
    }

    func speak(_ text: String, locale: Locale) {
        guard headphonesConnected, !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: locale)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The highest-quality installed voice for the language (Premium, then Enhanced, then default), preferring
    /// the app's region ("de-DE" over "de-AT") when there is a choice.
    static func voice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        let best = candidates.max { lhs, rhs in
            let lhsRegion = region.map { lhs.language.hasSuffix($0) } ?? false
            let rhsRegion = region.map { rhs.language.hasSuffix($0) } ?? false
            if lhs.quality != rhs.quality { return lhs.quality.rawValue < rhs.quality.rawValue }
            return !lhsRegion && rhsRegion
        }
        return best ?? AVSpeechSynthesisVoice(language: locale.identifier)
    }

    fileprivate func finished() {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    #else
    var headphonesConnected: Bool { false }
    func speak(_ text: String, locale: Locale) {}
    func stop() {}
    #endif
}

#if os(iOS)
extension WorkoutSpeaker: AVSpeechSynthesizerDelegate {
    /// Hands the audio back once the sentence is done, so the music returns to full volume.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
#endif
