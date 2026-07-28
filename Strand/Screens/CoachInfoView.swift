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

    /// Apple Health-style leading-icon coloring (SettingsView's "App icon colors") — same switch that
    /// recolors the More tab and the rest of Coach's screens. See `CoachIconColors`.
    @AppStorage("noop.moreRowAppleHealthColors") private var appleHealthColors = true

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
                        point("cpu", "coach.firstUse.model",
                              "It's only as good as its model",
                              "The coach's judgement is the model's judgement. A small or cheap model gives shallow, generic answers; a capable one reasons well over your numbers.")
                        point("hand.thumbsup", "coach.firstUse.support",
                              "It's support, not the last word",
                              "Treat its answers as a helpful second opinion. Don't follow them blindly — keep using your own judgement.")
                        point("cross.case", "coach.firstUse.notMedical",
                              "It's not a doctor, therapist or trainer",
                              "For anything medical, or anything that really matters, talk to a qualified professional. The coach can be wrong and can miss context you didn't share.")
                        point("arrow.up.forward.app", "coach.firstUse.dataConsent",
                              coach.dataConsent ? "It works with your data" : "It needs your data, off by default",
                              coach.dataConsent
                              ? "To answer well, it sends a short summary of your relevant metrics to the provider you chose — using your own key, and only when you ask. Nothing is sent otherwise."
                              : "Data sharing is OFF right now, so answers stay generic. Turn on \"Let the coach use my data\" in Settings → Privacy & data to have it answer from your real metrics — using your own key, and only when you ask.")
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

    private func point(_ icon: String, _ colorID: String, _ title: LocalizedStringKey,
                       _ body: LocalizedStringKey) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(StrandFont.headline)
                    .foregroundStyle(appleHealthColors ? CoachIconColors.color(for: colorID) : StrandPalette.accent)
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

    /// Apple Health-style leading-icon coloring (SettingsView's "App icon colors") — same switch that
    /// recolors the More tab and the rest of Coach's screens. See `CoachIconColors`.
    @AppStorage("noop.moreRowAppleHealthColors") private var appleHealthColors = true

    private var providerName: String { coach.provider.displayName }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("How it works", icon: "sparkles", colorID: "coach.info.howItWorks") {
                        para("NOOP first interprets your question locally. Its local data planner checks which categories you allowed and prepares only the relevant compact context — for example recovery, workouts, a journal pattern or a long-term aggregate. The provider never gets direct access to your database.")
                        para("On iPhone, Nomic can also find related text in your approved memories, your own chat messages and journal notes. This semantic search runs entirely on the iPhone. It does not embed raw sensor streams or numerical health histories, and it falls back to keyword search if the local model is not ready.")
                        para("The model then writes the answer in plain language. When a specific number is needed, it can use a permitted tool; NOOP checks that tool locally before returning a result.")
                    }

                    section("What stays here, what's sent", icon: "lock.shield", colorID: "coach.info.whatIsShared") {
                        para("Everything is computed on \(Platform.deviceNounPhrase). The coach is the ONE feature in NOOP that talks to the internet.")
                        para("When you ask a question with data sharing on, it sends a short text summary or a permitted tool result to your chosen provider — never raw sensor streams or unrestricted database access. With data sharing off, it sends only your question. Nothing leaves until you ask or opt into a Coach automation.")
                        para("Deep historical questions use on-device aggregates, not years of daily rows. Sensitive journal information is excluded unless you separately allow it in Data access for an explicitly sensitive question.")
                    }

                    section("Provider & model", icon: "server.rack", colorID: "coach.info.providerModel") {
                        para("You bring your own API key. The provider — right now \(providerName) — is who actually receives your data, so it's the real privacy choice: pick one you trust, and check how they handle it.")
                        para("Nomic is not the coaching model. It only retrieves relevant local text and is loaded on demand, then released after inactivity, a memory warning or a privacy change. The selected provider model still reasons over the compact context and writes the reply.")
                        para("The coaching model runs the conversation. Background models for chat summaries or card reads are optional and off unless you set them up (Settings → Connection & model). NOOP never sends more personal data than a request needs.")
                    }

                    section("Why the model matters", icon: "cpu", colorID: "coach.info.whyModelMatters") {
                        para("The coach is only as sharp as the model behind it. A stronger model reasons better over your data and gives advice worth acting on; a weak or very cheap one tends to be shallow or generic. That's why the default coaching model is a capable one, not a mini one — a bad first answer is a bad first impression for no reason you chose.")
                    }

                    section("Its limits", icon: "exclamationmark.triangle", colorID: "coach.info.limits") {
                        para("It's a support tool, not a medical or clinical authority. It can be wrong, it can miss context you didn't tell it, and it never replaces professional advice. Use it to think — not to obey.")
                    }

                    section("Turn it off any time", icon: "power", colorID: "coach.info.limits") {
                        para("More → AI Coach lets you disable the whole feature. Its buttons, Today entries and check-ins disappear, while your on-device chats and health data remain saved unless you remove them yourself.")
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

    private func section<Content: View>(_ title: LocalizedStringKey, icon: String, colorID: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(StrandFont.headline)
                    .foregroundStyle(appleHealthColors
                                     ? CoachIconColors.color(for: colorID)
                                     : StrandPalette.accent)
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
