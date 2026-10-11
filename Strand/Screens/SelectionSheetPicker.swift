import SwiftUI
import StrandDesign

/// A choice that slides up from the bottom instead of a small pop-up menu: the options sit where the
/// thumb is, each with room for a line of explanation, and the current one is ticked.
struct SelectionSheetPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var detail: String?
        var id: Value { value }
    }

    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [Option]

    @State private var isPresented = false

    private var current: Option? { options.first { $0.value == selection } }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: NoopMetrics.space1) {
                Text(verbatim: current?.title ?? "")
                Image(systemName: "chevron.up.chevron.down")
                    .font(StrandFont.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: current?.title ?? ""))
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                List {
                    ForEach(options) { option in
                        Button {
                            selection = option.value
                            isPresented = false
                        } label: {
                            row(option)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                    }
                }
                .navigationTitle(Text(title))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { isPresented = false } }
                }
            }
            .presentationDetents([.height(sheetHeight)])
            .presentationDragIndicator(.visible)
            #if os(macOS)
            .frame(minWidth: 360, minHeight: sheetHeight)
            #endif
        }
    }

    private func row(_ option: Option) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(verbatim: option.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let detail = option.detail {
                    Text(verbatim: detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            if option.value == selection {
                Image(systemName: "checkmark")
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// Tall enough for every option without scrolling, capped so a long list still leaves the
    /// screen behind it visible.
    private var sheetHeight: CGFloat {
        let rowHeight: CGFloat = options.contains { $0.detail != nil } ? 64 : 52
        return min(620, 120 + CGFloat(options.count) * rowHeight)
    }
}
