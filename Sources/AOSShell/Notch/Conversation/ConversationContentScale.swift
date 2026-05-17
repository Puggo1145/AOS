import SwiftUI

enum ConversationContentScale: Sendable, Equatable {
    case normal
    case focused

    var toolFontSize: CGFloat {
        switch self {
        case .normal: return 12
        case .focused: return 14
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .normal: return .regular
        case .focused: return .semibold
        }
    }

    var toolIconSize: CGFloat {
        switch self {
        case .normal: return 11
        case .focused: return 13
        }
    }

    var toolChevronSize: CGFloat {
        switch self {
        case .normal: return 10
        case .focused: return 12
        }
    }

    var agentEmojiFontSize: CGFloat {
        switch self {
        case .normal: return 13
        case .focused: return 15
        }
    }

    var thinkingFontSize: CGFloat {
        switch self {
        case .normal: return 12
        case .focused: return 14
        }
    }

    var thinkingLineHeight: CGFloat {
        switch self {
        case .normal: return 16
        case .focused: return 19
        }
    }

    var replyTheme: ReplyMarkdownTheme {
        switch self {
        case .normal: return .normal
        case .focused: return .focused
        }
    }
}

enum ReplyMarkdownTheme: Sendable, Equatable {
    case normal
    case focused
}
