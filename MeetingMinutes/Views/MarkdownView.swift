import SwiftUI

/// Lightweight, dependency-free Markdown renderer for the generated minutes.
/// Handles the subset the minutes use: ATX headings (`#`–`######`), bullet
/// lists (`-`, `*`), ordered lists (`1.`), and paragraphs — each rendered with
/// inline bold/italic/links via `AttributedString`.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                row(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ordered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let text):
            inline(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
    }

    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    // MARK: - Parsing

    enum Block {
        case heading(level: Int, text: String)
        case bullet(String)
        case ordered(number: Int, text: String)
        case paragraph(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let heading = headingBlock(line) {
                blocks.append(heading)
            } else if let bullet = bulletText(line) {
                blocks.append(.bullet(bullet))
            } else if let ordered = orderedItem(line) {
                blocks.append(.ordered(number: ordered.number, text: ordered.text))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    private static func headingBlock(_ line: String) -> Block? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        guard level <= 6, index < line.endIndex, line[index] == " " else { return nil }
        return .heading(level: level, text: String(line[index...]).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber), let number = Int(prefix) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (number, String(line[line.index(after: afterDot)...]))
    }
}

#Preview {
    MarkdownView(markdown: """
    ## Summary
    The team agreed to **ship Friday** and move the demo to next week.

    ## Key Decisions
    - Launch date set to Friday
    - Demo postponed

    ## Action Items
    - **Jun** — update the release calendar (by Thursday)
    - **Unassigned** — draft the announcement
    """)
    .padding()
    .frame(width: 420)
}
