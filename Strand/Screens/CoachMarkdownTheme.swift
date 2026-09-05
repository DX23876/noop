import SwiftUI
import MarkdownUI
import StrandDesign

/// The MarkdownUI theme for Coach replies.
///
/// LLM chat replies (OpenAI / Anthropic / Gemini) arrive as GitHub-flavored
/// Markdown — overwhelmingly bold, bullet/numbered lists, `###` headings, and the
/// occasional table for a weekly plan. This theme renders that set in the Strand look.
///
/// SIZED FOR A PAGE, NOT A BUBBLE. A coach reply is usually several paragraphs, and it is now laid out
/// as content in a reading column rather than inside a speech bubble. That changes what the type has to
/// do: the old sizing kept every heading near body size so a `#` could not shout inside a 560pt bubble,
/// which also meant a structured answer read as one undifferentiated block. With room to breathe, the
/// heading levels are allowed to actually differ, line spacing is set for reading rather than for
/// fitting, and the space between blocks is what carries the structure.
extension Theme {
    static let strand = Theme()
        // Base body text — mirrors StrandFont.body (15 / regular).
        // 16 rather than 15: `StrandFont.body` is sized for labels and rows, and a long answer read
        // at that size is noticeably harder work. One point is the difference between skimming and
        // reading.
        .text {
            ForegroundColor(StrandPalette.textPrimary)
            FontSize(16)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(StrandPalette.accentHover)
            BackgroundColor(StrandPalette.surfaceInset)
        }
        .link {
            ForegroundColor(StrandPalette.accent)
        }
        // Headings: h1/h2 land at headline (17 / semibold), h3 just above body,
        // h4–h6 as overline-ish small caps labels.
        // The generous top margins are the point: a heading is a break in the reading, and the space
        // ABOVE it is what the eye uses to find one. Below it stays tight, so a heading sits with the
        // text it introduces rather than floating between two blocks.
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 22, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(21)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 20, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(19)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 18, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 5)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13)
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(12)
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        // 0.30em line spacing and a full blank line between paragraphs. Both were tuned for a narrow
        // bubble where vertical space was the scarce thing; in a reading column the scarce thing is the
        // reader's patience with a wall of text.
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.30))
                .markdownMargin(top: 0, bottom: 14)
        }
        .listItem { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.26))
                .markdownMargin(top: .em(0.42))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .markdownTextStyle {
                    ForegroundColor(StrandPalette.textSecondary)
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(StrandPalette.accent.opacity(0.6))
                        .frame(width: 3)
                }
                .markdownMargin(top: 4, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                    }
                    .padding(10)
            }
            .background(StrandPalette.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .markdownMargin(top: 4, bottom: 8)
        }
        .thematicBreak {
            StrandPalette.hairline
                .frame(height: 1)
                .markdownMargin(top: 10, bottom: 10)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: StrandPalette.hairline))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, StrandPalette.surfaceInset)
                )
                .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    FontSize(.em(0.9))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .relativeLineSpacing(.em(0.2))
        }
}
