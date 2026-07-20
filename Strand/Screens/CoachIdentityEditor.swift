import SwiftUI
import StrandDesign
import PhotosUI

/// The coach-identity editor (#R9): name, avatar (a curated symbol OR the user's own photo), and the
/// phrasing-lean voice — plus one-tap Svea / Marv presets. Pushed from the Coaching settings subpage.
/// Everything is on-device: the photo is written to Application Support by `CoachIdentityStore`, and only
/// the NAME and voice lean ever reach the model (never the picture). Design tokens only; shared macOS+iOS.
struct CoachIdentityEditor: View {
    @ObservedObject private var store = CoachIdentityStore.shared

    /// Local editable copy of the name so mid-edit blanks don't snap back; committed (non-empty) as it
    /// changes and on disappear.
    @State private var nameDraft: String = ""
    /// PhotosPicker selection; loaded to Data and handed to the store off the main thread's critical path.
    @State private var photoItem: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                preview
                presetsCard
                nameCard
                avatarCard
                voiceCard
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Coach identity")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { nameDraft = store.identity.name }
        .onDisappear { store.setName(nameDraft) }
        .onChangeCompat(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.setPhoto(data)
                }
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            CoachAvatarView(size: 88)
            Text(nameDraft.isEmpty ? store.identity.name : nameDraft)
                .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var presetsCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start from a coach").strandOverline()
                Text("Svea and Marv are two ready-made coaches — a name, a picture and a tone. Pick one, then change anything you like.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    presetButton(.svea, label: "Svea")
                    presetButton(.marv, label: "Marv")
                }
            }
        }
    }

    private func presetButton(_ preset: CoachIdentity, label: LocalizedStringKey) -> some View {
        Button {
            store.applyPreset(preset)
            nameDraft = preset.name
        } label: {
            HStack(spacing: 8) {
                CoachAvatarView(size: 30, identity: preset)
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Use the \(label) preset"))
    }

    private var nameCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").strandOverline()
                TextField("Coach name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .onChangeCompat(of: nameDraft) { store.setName($0) }
                    .accessibilityLabel("Coach name")
            }
        }
    }

    private var avatarCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Picture").strandOverline()
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(CoachAvatar.presetSymbols, id: \.self) { symbol in
                        symbolTile(symbol)
                    }
                }
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Upload a photo", systemImage: "photo.on.rectangle")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                    }
                    Spacer(minLength: 8)
                    if case .photo = store.identity.avatar {
                        Button {
                            store.setPreset(symbol: CoachIdentity.default.avatar.presetSymbolOrDefault)
                        } label: {
                            Text("Remove photo").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Your photo stays on \(Platform.deviceNounPhrase). The coach is never shown your picture — only its name and tone reach your provider.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func symbolTile(_ symbol: String) -> some View {
        let selected: Bool = {
            if case .preset(let s) = store.identity.avatar { return s == symbol }
            return false
        }()
        return Button {
            store.setPreset(symbol: symbol)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(selected ? .white : StrandPalette.accent)
                .frame(width: 52, height: 52)
                .background(selected ? StrandPalette.accent : StrandPalette.accent.opacity(0.12),
                            in: Circle())
                .overlay(Circle().strokeBorder(selected ? Color.clear : StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Avatar option")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var voiceCard: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tone").strandOverline()
                Picker("Tone", selection: Binding(get: { store.identity.voice },
                                                  set: { store.setVoice($0) })) {
                    ForEach(CoachVoice.allCases) { v in Text(LocalizedStringKey(v.label)).tag(v) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Coach tone")
                Text("A light lean in how the coach phrases things, on top of its coaching style. It never changes what the coach decides.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension CoachAvatar {
    /// The symbol name if this is a preset, else the default identity's preset symbol — used when
    /// "remove photo" needs a symbol to fall back to.
    var presetSymbolOrDefault: String {
        if case .preset(let s) = self { return s }
        if case .preset(let s) = CoachIdentity.default.avatar { return s }
        return "person.crop.circle.fill"
    }
}
