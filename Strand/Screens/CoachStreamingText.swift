//  CoachStreamingText.swift
//  NOOP · The coach's reply as it arrives — words settling in instead of text jumping onto the screen.
//
//  A streamed reply used to grow by re-laying-out a longer and longer string, which reads as flicker
//  rather than as someone writing. This renders the in-flight text so each word fades up from a blur as it
//  lands, then holds still.
//
//  Two deliberate limits, both structural rather than stylistic:
//
//  • It runs on plain `Text`. The finished reply is rendered by MarkdownUI (`Markdown(...)`), and a
//    `TextRenderer` only attaches to `Text` — so the CHAT shows this while `sending`, then swaps to the
//    real Markdown view (lists, bold, headings) the moment the reply completes. The swap is invisible
//    because both use the same font and insets.
//  • `TextRenderer` is iOS 18 / macOS 15. Below that — and whenever Reduce Motion is on — `CoachStreamingText`
//    simply renders the text, no effect. Nothing is load-bearing: the words are all there either way.

import SwiftUI
import StrandDesign

/// The in-flight assistant text. Applies the per-word settle where the OS supports it and the user hasn't
/// asked for less motion; otherwise it is a plain `Text` with the same typography.
struct CoachStreamingText: View {
    let text: String
    /// Reduce Motion is passed in rather than read here so the parent's single environment read governs the
    /// whole chat's motion policy.
    var animated: Bool = true

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, *), animated {
            Text(text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                // `elapsed` drives the renderer: it advances with the text length, so a word that arrives
                // later starts its settle later. Animating on the character count (not a timer) means the
                // effect is driven by the STREAM, and a paused stream simply holds still.
                .textRenderer(CoachStreamRenderer(elapsed: Double(text.count)))
                .animation(.easeOut(duration: 0.45), value: text.count)
        } else {
            Text(text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

/// Fades and lifts each run of the reply as it arrives. Deliberately per-RUN rather than per-glyph: a glyph
/// pass on a long reply re-runs for every token and costs far more than it looks, and the word-level settle
/// is what actually reads as writing.
@available(iOS 18.0, macOS 15.0, *)
private struct CoachStreamRenderer: TextRenderer, Animatable {
    /// Grows with the text; `Animatable` interpolates it so each new run animates in rather than appearing.
    var elapsed: Double

    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let runs = Array(layout.flatMap { $0 }.flatMap { $0 })
        guard !runs.isEmpty else { return }
        // How many runs are fully settled: everything except the tail, which is still arriving. A short
        // window (the last few runs) keeps the effect at the write head instead of shimmering the whole
        // paragraph on every token.
        let window = 6.0
        let settledUpTo = max(0, Double(runs.count) - window)

        for (index, run) in runs.enumerated() {
            // 0 = just landed, 1 = fully settled.
            let progress = min(1, max(0, (Double(index) < settledUpTo)
                                      ? 1
                                      : (elapsed - Double(index)) / window))
            var copy = context
            copy.opacity = progress
            copy.addFilter(.blur(radius: (1 - progress) * 3))
            copy.translateBy(x: 0, y: (1 - progress) * 4)
            copy.draw(run)
        }
    }
}

/// The write head: a slim caret that blinks at the end of an in-flight reply. Shown alongside the streaming
/// text on systems without `TextRenderer`, where it is the only "still writing" cue the bubble has.
struct CoachStreamCaret: View {
    var animated: Bool = true
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(StrandPalette.accent)
            .frame(width: 2, height: 15)
            .opacity(on ? 1 : 0.15)
            .animation(animated ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : nil,
                       value: on)
            .onAppear { if animated { on.toggle() } }
            .accessibilityHidden(true)
    }
}
