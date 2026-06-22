import Foundation

/// Converts the minutes Markdown into clean, email-ready plain text — no `#`,
/// no `**`, headings as plain lines, list markers normalized to "• ".
enum MinutesExport {
    static func plainText(_ markdown: String) -> String {
        var out: [String] = []
        for block in MarkdownView.parse(markdown) {
            switch block {
            case .heading(_, let text):
                if !out.isEmpty { out.append("") }   // blank line before each section
                out.append(stripInline(text))
            case .bullet(let text):
                out.append("• " + stripInline(text))
            case .ordered(let number, let text):
                out.append("\(number). " + stripInline(text))
            case .paragraph(let text):
                out.append(stripInline(text))
            }
        }
        return out.joined(separator: "\n")
    }

    /// Removes inline Markdown (`**bold**`, `*italic*`, links) keeping the text.
    private static func stripInline(_ string: String) -> String {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return String(attributed.characters)
        }
        return string
    }
}
