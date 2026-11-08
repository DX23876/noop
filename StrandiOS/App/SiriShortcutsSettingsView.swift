#if os(iOS)
import SwiftUI
import AppIntents
import StrandDesign

/// Surfaces NOOP's already-registered App Intents (see StrandiOS/System/NOOPAppIntents.swift) in the
/// UI so users discover them. `NOOPShortcuts` auto-registers "Sync Strap", "Buzz Strap" and "Mark a Moment" with
/// Siri/Spotlight/Shortcuts, but nothing in-app advertised them — this is the iOS analogue of the
/// Mac's strap-double-tap-runs-a-Shortcut feature. Apple's `SiriTipView`/`ShortcutsLink` (iOS 16+)
/// do exactly that: tip the user on the spoken phrase and deep-link into the Shortcuts app, scoped to
/// this app automatically.
struct SiriShortcutsSettingsView: View {
    var body: some View {
        ScreenScaffold(title: "Siri & Shortcuts",
                       subtitle: classicOnlySubtitle("Run NOOP actions hands-free.")) {
            if NoopVisualStyle.skin == .forge {
                forgeActions
                forgeExport
            } else {
                tips
                shortcutsCard
            }
        }
        .pagePicture("mic.fill", accent: "sparkles", tint: .purple)
    }

    /// What NOOP answers to, one row per action, with the words that start it.
    private var forgeActions: some View {
        NoopCard(padding: NoopMetrics.space3) {
            VStack(spacing: 0) {
                forgeAction("bolt.fill", StrandPalette.chargeColor, String(localized: "What's my Charge?"), String(localized: "today's score, read aloud"))
                Divider().overlay(StrandPalette.hairline).padding(.leading, 52)
                forgeAction("arrow.triangle.2.circlepath", StrandPalette.metricCyan, String(localized: "Sync my strap"), String(localized: "pulls the latest from the strap"))
                Divider().overlay(StrandPalette.hairline).padding(.leading, 52)
                forgeAction("waveform", StrandPalette.effortColor, String(localized: "Buzz my strap"), String(localized: "the strap vibrates"))
                Divider().overlay(StrandPalette.hairline).padding(.leading, 52)
                forgeAction("mappin", StrandPalette.restColor, String(localized: "Mark a moment"), String(localized: "a marker on today's timeline"))
                Divider().overlay(StrandPalette.hairline).padding(.leading, 52)
                forgeAction("target", StrandPalette.metricPurple, String(localized: "How are my goals?"), String(localized: "where your goals stand"))
            }
        }
    }

    private func forgeAction(_ symbol: String, _ tint: Color, _ title: String, _ note: String) -> some View {
        ForgeTileRow(symbol: symbol, tint: tint, title: title, subtitle: note) { EmptyView() }
            .padding(.vertical, NoopMetrics.space1)
    }

    private var forgeExport: some View {
        ForgeListGroup("Shortcuts") {
            ForgeLinkRow(title: "Shortcut export", subtitle: "Today's scores as a shortcut input") {
                ShortcutExportSettingsView()
            }
            Divider().overlay(StrandPalette.hairline)
            ShortcutsLink()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, NoopMetrics.space2)
        }
    }

    private var tips: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .appleInspiredMenuIcon("siriShortcuts")
                        .accessibilityHidden(true)
                    Text("Ready-made actions")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Sync your strap, buzz it or mark a moment from Siri, Spotlight, the Shortcuts app, or a Back-Tap / automation. No setup needed.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SiriTipView(intent: SyncStrapIntent(), isVisible: .constant(true))
                    .siriTipViewStyle(.dark)
                SiriTipView(intent: BuzzStrapIntent(), isVisible: .constant(true))
                    .siriTipViewStyle(.dark)
                SiriTipView(intent: MarkMomentIntent(), isVisible: .constant(true))
                    .siriTipViewStyle(.dark)
            }
        }
    }

    private var shortcutsCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .appleInspiredMenuIcon("siriShortcuts")
                        .accessibilityHidden(true)
                    Text("Build your own")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Wire NOOP's actions into a Back-Tap, a focus automation, or a longer Shortcut. For example, double-tap the back of your iPhone to buzz the strap.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutsLink()
            }
        }
    }
}
#endif
