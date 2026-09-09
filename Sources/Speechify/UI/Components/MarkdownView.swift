import SwiftUI

/// Renders block-level markdown: headings, bullet and numbered lists, checkboxes, paragraphs.
///
/// `AttributedString(markdown:)` handles inline emphasis well but flattens every block
/// into one run, so headings and lists lose their shape. This splits the document into
/// blocks first and lets `AttributedString` do the inline work within each.
struct MarkdownView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 2 ? DS.Font.notesHeading : DS.Font.notesSubheading)
                .padding(.top, level <= 2 ? DS.Space.m : DS.Space.xs)
        case .paragraph(let text):
            inline(text)
                .font(DS.Font.body)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text("•").foregroundStyle(DS.Color.textSecondary)
                        inline(item).font(DS.Font.body)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text("\(index + 1).")
                            .foregroundStyle(DS.Color.textSecondary)
                            .monospacedDigit()
                        inline(item).font(DS.Font.body)
                    }
                }
            }
        case .checklist(let items):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Image(systemName: item.done ? "checkmark.square" : "square")
                            .foregroundStyle(item.done ? DS.Color.success : DS.Color.textSecondary)
                        inline(item.text)
                            .font(DS.Font.body)
                            .strikethrough(item.done, color: DS.Color.textSecondary)
                    }
                }
            }
        case .divider:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

enum MarkdownBlock {
    struct CheckItem {
        let done: Bool
        let text: String
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case numbered([String])
    case checklist([CheckItem])
    case divider

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var checks: [CheckItem] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
            if !checks.isEmpty { blocks.append(.checklist(checks)); checks = [] }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flush()
                continue
            }
            if line == "---" || line == "***" {
                flush()
                blocks.append(.divider)
                continue
            }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
                continue
            }
            if let check = checkItem(from: line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbers.isEmpty { flush() }
                checks.append(check)
                continue
            }
            if let item = listItem(from: line, markers: ["- ", "* ", "+ "]) {
                if !paragraph.isEmpty || !numbers.isEmpty || !checks.isEmpty { flush() }
                bullets.append(item)
                continue
            }
            if let item = numberedItem(from: line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !checks.isEmpty { flush() }
                numbers.append(item)
                continue
            }
            if !bullets.isEmpty || !numbers.isEmpty || !checks.isEmpty { flush() }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    private static func listItem(from line: String, markers: [String]) -> String? {
        for marker in markers where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func checkItem(from line: String) -> CheckItem? {
        for marker in ["- [ ] ", "* [ ] "] where line.hasPrefix(marker) {
            return CheckItem(done: false, text: String(line.dropFirst(marker.count)))
        }
        for marker in ["- [x] ", "- [X] ", "* [x] ", "* [X] "] where line.hasPrefix(marker) {
            return CheckItem(done: true, text: String(line.dropFirst(marker.count)))
        }
        return nil
    }

    private static func numberedItem(from line: String) -> String? {
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
            digits += 1
        }
        guard digits > 0, index < line.endIndex, line[index] == "." else { return nil }
        let rest = line[line.index(after: index)...]
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
