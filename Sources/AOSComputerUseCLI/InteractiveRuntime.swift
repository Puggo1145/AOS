import Foundation

struct InteractiveSelectionOption<Value: Sendable>: Sendable {
    let title: String
    let value: Value
}

enum InteractiveCLISessionControl: Error {
    case cancelled
}

struct InteractiveSelectionMenu<Value: Sendable>: Sendable {
    private let visibleOptionCount: Int
    private let allowsPrefixMatching: Bool
    let title: String
    let options: [InteractiveSelectionOption<Value>]

    init(
        title: String,
        options: [InteractiveSelectionOption<Value>],
        visibleOptionCount: Int = 8,
        allowsPrefixMatching: Bool = false
    ) {
        precondition(visibleOptionCount > 0, "interactive selection visibleOptionCount must be positive")
        self.title = title
        self.options = options
        self.visibleOptionCount = visibleOptionCount
        self.allowsPrefixMatching = allowsPrefixMatching
    }

    func select(using io: InteractiveCLIIO) async throws -> Value {
        guard !options.isEmpty else {
            throw UsageError("\(title) has no selectable options")
        }
        var index = 0
        var prefix = ""
        var region = TerminalRenderRegion()
        do {
            await region.replace(with: render(selectedIndex: index, prefix: prefix), io: io)
            while true {
                let filteredOptions = filteredOptions(prefix: prefix)
                switch try await io.readKey() {
                case .up:
                    guard !filteredOptions.isEmpty else {
                        continue
                    }
                    index = index == 0 ? filteredOptions.count - 1 : index - 1
                    await region.replace(with: render(selectedIndex: index, prefix: prefix), io: io)
                case .down:
                    guard !filteredOptions.isEmpty else {
                        continue
                    }
                    index = (index + 1) % filteredOptions.count
                    await region.replace(with: render(selectedIndex: index, prefix: prefix), io: io)
                case .character(let value):
                    guard allowsPrefixMatching else {
                        continue
                    }
                    prefix.append(value)
                    index = 0
                    await region.replace(with: render(selectedIndex: index, prefix: prefix), io: io)
                case .backspace:
                    guard allowsPrefixMatching, !prefix.isEmpty else {
                        continue
                    }
                    prefix.removeLast()
                    index = 0
                    await region.replace(with: render(selectedIndex: index, prefix: prefix), io: io)
                case .left, .quit:
                    await region.clear(io: io)
                    throw InteractiveCLISessionControl.cancelled
                case .right, .confirm:
                    guard !filteredOptions.isEmpty else {
                        continue
                    }
                    let value = filteredOptions[index].value
                    await region.clear(io: io)
                    return value
                }
            }
        } catch {
            await region.clear(io: io)
            throw error
        }
    }

    private func render(selectedIndex: Int, prefix: String) -> String {
        let filteredOptions = filteredOptions(prefix: prefix)
        let visibleRange = visibleRange(containing: selectedIndex, optionCount: filteredOptions.count)
        var lines = [
            title,
            String(repeating: "-", count: title.count),
        ]
        if allowsPrefixMatching {
            lines.append("Prefix: \(prefix)")
        }
        if filteredOptions.isEmpty {
            lines.append("No matches")
        } else if filteredOptions.count > visibleOptionCount {
            lines.append("Showing \(visibleRange.lowerBound + 1)-\(visibleRange.upperBound) of \(filteredOptions.count)")
        }
        for index in visibleRange {
            let option = filteredOptions[index]
            lines.append("\(index == selectedIndex ? ">" : " ") \(option.title)")
        }
        lines.append("Use Up/Down, Enter to select, Q to cancel.")
        return lines.joined(separator: "\n")
    }

    private func filteredOptions(prefix: String) -> [InteractiveSelectionOption<Value>] {
        guard !prefix.isEmpty else {
            return options
        }
        return options.filter {
            $0.title.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    private func visibleRange(containing selectedIndex: Int, optionCount: Int) -> Range<Int> {
        guard optionCount > 0 else {
            return 0..<0
        }
        let visibleCount = min(visibleOptionCount, optionCount)
        let maxStart = max(optionCount - visibleCount, 0)
        let start = min(max(selectedIndex - visibleCount + 1, 0), maxStart)
        return start..<(start + visibleCount)
    }
}

enum InteractiveOutputSection {
    static func render(title: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return "\(title)\n\(String(repeating: "-", count: title.count))\n\(trimmed)"
    }
}

struct TerminalRenderRegion {
    private var renderedLineCount = 0

    mutating func replace(with text: String, io: InteractiveCLIIO) async {
        if renderedLineCount > 0 {
            await io.write(Self.clearSequence(lineCount: renderedLineCount))
        }
        await io.write(text + "\n")
        renderedLineCount = Self.renderedLineCount(text)
    }

    mutating func clear(io: InteractiveCLIIO) async {
        guard renderedLineCount > 0 else {
            return
        }
        await io.write(Self.clearSequence(lineCount: renderedLineCount))
        renderedLineCount = 0
    }

    private static func renderedLineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func clearSequence(lineCount: Int) -> String {
        guard lineCount > 0 else {
            return ""
        }
        let clearLines = String(repeating: "\u{001B}[2K\u{001B}[1B", count: lineCount)
        return "\u{001B}[\(lineCount)A" + clearLines + "\u{001B}[\(lineCount)A"
    }
}

extension InteractiveCLIIO {
    func promptRequired(_ prompt: String) async throws -> String {
        let value = try await readLine(prompt: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        await clearCompletedPromptLine()
        guard !value.isEmpty else {
            throw UsageError("missing value for \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return value
    }

    func promptOptional(_ prompt: String) async throws -> String? {
        let value = try await readLine(prompt: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        await clearCompletedPromptLine()
        return value.isEmpty ? nil : value
    }

    private func clearCompletedPromptLine() async {
        await write("\u{001B}[1A\u{001B}[2K")
    }
}
