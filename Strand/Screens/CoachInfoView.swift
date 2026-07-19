import SwiftUI
import StrandDesign

/// The coach's transparency surface (#P6). Two pieces sharing one voice:
///
///  - `CoachFirstUseSheet` — a one-time, must-acknowledge dialog before the first coaching conversation.
///    It sets honest expectations (the coach is only as good as its model, it isn't a doctor, it works
///    with your data) rather than reciting legalese.
///  - `CoachInfoView` — the fuller "how it works / what's shared / why the model matters / its limits"
///    page, reachable from settings and referenced by the dialog.
///
/// Kept in its own file so it stays merge-clean against upstream. Design tokens only.

// MARK: - First-use acknowledgement (6.3)

/// UserDefaults key: set once the user has acknowledged the coach's first-use note, so it appears only
/// before the FIRST conversation, never again.
enum CoachFirstUse {
    static let acknowledgedKey = "coach.firstUseAcknowledged"
}

/// The trust/expectations dialog shown once before the first coaching conversation. Clear, not panicky,
/// not over-legal — the point is that the user goes in knowing what the coach is and isn't.
struct CoachFirstUseSheet: View {
    @EnvironmentObject var coach: AICoachEngine
    /// Called when the user acknowledges — the host sets the persisted flag and dismisses.
    let onAcknowledge: () -> Void
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "hand.raised.fingers.spread")
                            .font(.system(size: 34))
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Before you talk to your coach")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("A quick, honest heads-up — not fine print.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }

                    VStack(spacing: 12) {
                        point("cpu",
                              "It's only as good as its model",
                              "The coach's judgement is the model's judgement. A small or cheap model gives shallow, generic answers; a capable one reasons well over your numbers.")
                        point("hand.thumbsup",
                              "It's support, not the last word",
                              "Treat its answers as a helpful second opinion. Don't follow them blindly — keep using your own judgement.")
                        point("cross.case",
                              "It's not a doctor, therapist or trainer",
                              "For anything medical, or anything that really matters, talk to a qualified professional. The coach can be wrong and can miss context you didn't share.")
                        point("arrow.up.forward.app",
                              "It works with your data",
                              "To answer well, it sends a short summary of your relevant metrics to the provider you chose — using your own key, and only when you ask. Nothing is sent otherwise.")
                    }

                    Button { showInfo = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle").accessibilityHidden(true)
                            Text("How it works, and exactly what's shared")
                        }
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)

                    NoopButton("Got it", systemImage: "checkmark", kind: .primary, action: onAcknowledge)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showInfo) { CoachInfoView().environmentObject(coach) }
        }
        .interactiveDismissDisabled(true)   // must be acknowledged, not swiped away
    }

    private func point(_ icon: String, _ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(body)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Info page (6.2)

/// The fuller "how the coach works" page: what runs locally vs. what's sent, the provider/model choice,
/// why model quality matters, and the coach's limits. Named to the provider so the privacy answer is
/// concrete, not abstract.
struct CoachInfoView: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    private var providerName: String { coach.provider.displayName }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("How it works", icon: "sparkles") {
                        para("The coach reads a compact summary of your recent data — roughly your last two weeks plus 30-day averages and recent workouts — and can call small tools to fetch specific numbers on demand. Then it answers in plain language, grounded in those numbers rather than generic advice.")
                    }

                    section("What stays here, what's sent", icon: "lock.shield") {
                        para("Everything is computed on \(Platform.deviceNounPhrase). The coach is the ONE feature in NOOP that talks to the internet.")
                        para("When you ask a question with data-sharing on, it sends a short TEXT summary of the relevant metrics — never your raw sensor streams — to your chosen provider, using your own key. With data-sharing off, it sends only your question. Either way, nothing leaves until you ask.")
                    }

                    section("Provider & model", icon: "server.rack") {
                        para("You bring your own API key. The provider — right now \(providerName) — is who actually receives your data, so it's the real privacy choice: pick one you trust, and check how they handle it.")
                        para("The coaching model runs the conversation; cheaper background models handle chat summaries and quick card reads (Settings → Connection & model). NOOP never sends more personal data than a request needs.")
                    }

                    section("Why the model matters", icon: "cpu") {
                        para("The coach is only as sharp as the model behind it. A stronger model reasons better over your data and gives advice worth acting on; a weak or very cheap one tends to be shallow or generic. That's why the default coaching model is a capable one, not a mini one — a bad first answer is a bad first impression for no reason you chose.")
                    }

                    section("Its limits", icon: "exclamationmark.triangle") {
                        para("It's a support tool, not a medical or clinical authority. It can be wrong, it can miss context you didn't tell it, and it never replaces professional advice. Use it to think — not to obey.")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("How Coach works")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, icon: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func para(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
