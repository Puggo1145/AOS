import SwiftUI
@preconcurrency import MarkdownUI

// MARK: - ReplyMarkdownView
//
// Equatable wrapper around `Markdown` so SwiftUI skips re-parsing when text
// hasn't changed — otherwise every streaming token re-parses every visible
// turn (O(visible × tokens)).
struct ReplyMarkdownView: View, Equatable {
    let text: String
    var theme: ReplyMarkdownTheme = .normal

    var body: some View {
        Markdown(text)
            .markdownTheme(theme.markdownTheme)
            .markdownImageProvider(BlockedImageProvider())
            .markdownInlineImageProvider(BlockedInlineImageProvider())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

private extension ReplyMarkdownTheme {
    @MainActor
    var markdownTheme: Theme {
        switch self {
        case .normal: return .aosNotchPanel
        case .focused: return .aosNotchPanelFocused
        }
    }
}

// MARK: - Markdown theme
extension Theme {
    @MainActor
    static let aosNotchPanel: Theme = Theme()
        .text {
            FontFamily(.system(.monospaced))
            FontSize(13)
            ForegroundColor(.white.opacity(0.9))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.95))
            BackgroundColor(.white.opacity(0.10))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.4))
                }
                .markdownMargin(top: .em(0.6), bottom: .em(0.3))
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
                .markdownMargin(top: .em(0.5), bottom: .em(0.25))
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: .em(0), bottom: .em(0.5))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.95))
                    }
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .markdownMargin(top: .em(0.4), bottom: .em(0.5))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 2)
                }
                .markdownMargin(top: .em(0.3), bottom: .em(0.5))
        }

    @MainActor
    static let aosNotchPanelFocused: Theme = Theme()
        .text {
            FontFamily(.system(.monospaced))
            FontSize(15)
            FontWeight(.semibold)
            ForegroundColor(.white.opacity(0.94))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.95))
            FontWeight(.semibold)
            BackgroundColor(.white.opacity(0.10))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.35))
                }
                .markdownMargin(top: .em(0.6), bottom: .em(0.3))
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                }
                .markdownMargin(top: .em(0.5), bottom: .em(0.25))
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.08))
                }
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: .em(0), bottom: .em(0.5))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.95))
                        FontWeight(.semibold)
                    }
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .markdownMargin(top: .em(0.4), bottom: .em(0.5))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 2)
                }
                .markdownMargin(top: .em(0.3), bottom: .em(0.5))
        }
}

// Reply text is untrusted LLM output; the default MarkdownUI providers
// would fetch any URL the model emits in `![](…)`, turning the panel into
// an outbound beacon (prompt-injection → IP/online-state/timing leak).
private struct BlockedImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { EmptyView() }
}

private struct BlockedInlineImageProvider: InlineImageProvider {
    private struct Blocked: Error {}
    func image(with url: URL, label: String) async throws -> Image {
        throw Blocked()
    }
}
