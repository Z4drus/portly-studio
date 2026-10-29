import Foundation
import SwiftUI

// MARK: - Model

/// One block of a Markdown document, as Talvo issues, comments and documents
/// write them. Inline markup (bold, links, code spans) stays in the text and
/// is drawn by `MarkdownView.inline(_:)`.
enum MarkdownBlock: Hashable {
    /// `#` to `######`, level 1 to 6.
    case heading(level: Int, text: String)
    /// Lines joined with a space. A hard break (two trailing spaces or a
    /// trailing backslash) is kept as a newline.
    case paragraph(String)
    /// A bullet or numbered list. `start` is the first number, 1 for bullets.
    case list(items: [MarkdownListItem], ordered: Bool, start: Int)
    /// Fenced code, with the first word of the fence's info string.
    case code(language: String?, body: String)
    /// A `>` quote, parsed as a document of its own.
    case quote([MarkdownBlock])
    /// `---`, `***` or `___`.
    case rule
    /// A pipe table. Every row has as many cells as the header.
    case table(header: [String], rows: [[String]])
}

/// One entry of a list: its first paragraph, its task state, and whatever is
/// nested under it (a sub-list, more paragraphs, code).
struct MarkdownListItem: Hashable {
    var text: String
    /// nil for a plain item, false for `- [ ]`, true for `- [x]`.
    var checked: Bool? = nil
    var children: [MarkdownBlock] = []
}

// MARK: - Parser

/// Turns Markdown into blocks, line by line. Pure and forgiving: it never
/// throws, and a line it does not understand ends up in a paragraph, so no
/// text is ever dropped.
enum MarkdownParser {
    /// The blocks of a whole document. Accepts `\n`, `\r\n` and `\r` line endings.
    static func blocks(from markdown: String) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return parse(normalized.components(separatedBy: "\n"))
    }

    // MARK: Blocks

    /// Parses lines whose container markers (`>`, list indentation) are already gone.
    private static func parse(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
                index += 1
            } else if let fence = openingFence(line) {
                blocks.append(codeBlock(fence, lines: lines, index: &index))
            } else if let block = headingBlock(line) {
                blocks.append(block)
                index += 1
            } else if isRule(line) {
                blocks.append(.rule)
                index += 1
            } else if isTableStart(lines, at: index) {
                blocks.append(tableBlock(lines: lines, index: &index))
            } else if quoteContent(line) != nil {
                blocks.append(quoteBlock(lines: lines, index: &index))
            } else if let marker = listMarker(line) {
                blocks.append(listBlock(lines: lines, index: &index, first: marker))
            } else {
                blocks.append(paragraphBlock(lines: lines, index: &index))
            }
        }
        return blocks
    }

    /// Whether the line at `index` opens a block, which ends a paragraph in progress.
    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        return openingFence(line) != nil
            || headingBlock(line) != nil
            || isRule(line)
            || quoteContent(line) != nil
            || listMarker(line) != nil
            || isTableStart(lines, at: index)
    }

    // MARK: Paragraphs

    /// Lines up to the next blank line or the next block.
    private static func paragraphBlock(lines: [String], index: inout Int) -> MarkdownBlock {
        var paragraphLines = [lines[index]]
        index += 1
        while index < lines.count, !isBlank(lines[index]), !startsBlock(lines, at: index) {
            paragraphLines.append(lines[index])
            index += 1
        }
        return .paragraph(joinedParagraph(paragraphLines))
    }

    /// Joins paragraph lines with a space. Two trailing spaces or a trailing
    /// backslash make a hard break instead, kept as `\n`.
    private static func joinedParagraph(_ lines: [String]) -> String {
        var text = ""
        for (offset, line) in lines.enumerated() {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if offset == lines.count - 1 {
                text += trimmed
            } else if line.hasSuffix("  ") {
                text += trimmed + "\n"
            } else if trimmed.hasSuffix("\\"), !trimmed.hasSuffix("\\\\") {
                trimmed.removeLast()
                text += trimmed.trimmingCharacters(in: .whitespaces) + "\n"
            } else {
                text += trimmed + " "
            }
        }
        return text
    }

    // MARK: Headings and rules

    /// `# Title` to `###### Title`. A closing run of `#`, as in `## Title ##`, is dropped.
    private static func headingBlock(_ line: String) -> MarkdownBlock? {
        guard indentation(of: line) <= 3 else { return nil }
        let content = line.drop(while: isIndentation)
        let level = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = content.dropFirst(level)
        guard rest.first.map(isIndentation) ?? true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let lastKept = text.lastIndex(where: { $0 != "#" }) {
            if text.index(after: lastKept) < text.endIndex, isIndentation(text[lastKept]) {
                text = text[..<lastKept].trimmingCharacters(in: .whitespaces)
            }
        } else {
            text = ""
        }
        return .heading(level: level, text: text)
    }

    /// Three or more `-`, `*` or `_`, spaces allowed between them.
    private static func isRule(_ line: String) -> Bool {
        guard indentation(of: line) <= 3 else { return false }
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return marks.allSatisfy { $0 == first }
    }

    // MARK: Code

    /// The opening line of a fenced code block.
    private struct Fence {
        let character: Character
        let length: Int
        let indent: Int
        let language: String?
    }

    /// The fence a line opens: three or more backticks or tildes, then an
    /// optional info string whose first word is the language.
    private static func openingFence(_ line: String) -> Fence? {
        let content = line.drop(while: isIndentation)
        guard let character = content.first, character == "`" || character == "~" else { return nil }
        let length = content.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        let info = content.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // A backtick fence cannot carry backticks in its info string: "```x```" is inline code.
        if character == "`", info.contains("`") { return nil }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map { String($0) }
        return Fence(character: character, length: length, indent: indentation(of: line), language: language)
    }

    /// Whether a line closes the fence: the same character, at least as many, and nothing after.
    private static func closes(_ fence: Fence, _ line: String) -> Bool {
        let content = line.drop(while: isIndentation)
        let run = content.prefix(while: { $0 == fence.character }).count
        return run >= fence.length && content.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    /// A fenced code block. An unclosed fence runs to the end of the lines.
    private static func codeBlock(_ fence: Fence, lines: [String], index: inout Int) -> MarkdownBlock {
        var body: [String] = []
        index += 1
        while index < lines.count {
            let line = lines[index]
            index += 1
            if closes(fence, line) { break }
            body.append(stripIndentation(line, columns: fence.indent))
        }
        return .code(language: fence.language, body: body.joined(separator: "\n"))
    }

    // MARK: Quotes

    /// The rest of a line after its `>` marker and one space, or nil when the line is not quoted.
    private static func quoteContent(_ line: String) -> String? {
        guard indentation(of: line) <= 3 else { return nil }
        let content = line.drop(while: isIndentation)
        guard content.first == ">" else { return nil }
        var rest = content.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// Consecutive `>` lines, plus unmarked lines that lazily continue a quoted paragraph.
    private static func quoteBlock(lines: [String], index: inout Int) -> MarkdownBlock {
        var inner: [String] = []
        while index < lines.count {
            let line = lines[index]
            if let content = quoteContent(line) {
                inner.append(content)
            } else if let last = inner.last, !isBlank(last), !isBlank(line), !startsBlock(lines, at: index) {
                inner.append(line)
            } else {
                break
            }
            index += 1
        }
        return .quote(parse(inner))
    }

    // MARK: Lists

    /// A list item's marker: `-`, `*`, `+`, or a number followed by `.` or `)`.
    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int
        /// Column where the item's text starts, used to un-indent its other lines.
        let contentColumn: Int
        /// The text after the marker, leading spaces removed.
        let text: String
    }

    /// The marker a line starts with, if it is a list item.
    private static func listMarker(_ line: String) -> ListMarker? {
        guard !isRule(line) else { return nil }
        let indent = indentation(of: line)
        let content = line.drop(while: isIndentation)
        guard let first = content.first else { return nil }
        let ordered: Bool
        let number: Int
        let markerLength: Int
        if first == "-" || first == "*" || first == "+" {
            ordered = false
            number = 1
            markerLength = 1
        } else {
            let digits = content.prefix(while: { $0 >= "0" && $0 <= "9" })
            guard (1...9).contains(digits.count),
                  let delimiter = content.dropFirst(digits.count).first,
                  delimiter == "." || delimiter == ")",
                  let value = Int(digits)
            else { return nil }
            ordered = true
            number = value
            markerLength = digits.count + 1
        }
        let rest = content.dropFirst(markerLength)
        guard rest.first.map(isIndentation) ?? true else { return nil }
        return ListMarker(
            indent: indent,
            ordered: ordered,
            number: number,
            contentColumn: indent + markerLength + 1,
            text: String(rest.drop(while: isIndentation))
        )
    }

    /// A run of sibling items of one kind. A line indented two or more columns
    /// past the first marker belongs to the item above it, which is how lists nest.
    private static func listBlock(lines: [String], index: inout Int, first: ListMarker) -> MarkdownBlock {
        let childIndent = first.indent + 2
        var items: [MarkdownListItem] = []
        while index < lines.count {
            if isBlank(lines[index]) {
                // Blank lines between two items keep the list going.
                guard let next = nextNonBlank(lines, after: index),
                      let marker = listMarker(lines[next]),
                      marker.ordered == first.ordered, marker.indent < childIndent
                else { break }
                index = next
            }
            guard let marker = listMarker(lines[index]),
                  marker.ordered == first.ordered, marker.indent < childIndent
            else { break }
            index += 1

            var text = marker.text
            var checked: Bool?
            if let task = taskState(text) {
                checked = task.checked
                text = task.rest
            }
            let body = itemLines(marker, firstLine: text, lines: lines, index: &index, childIndent: childIndent)
            items.append(listItem(body, checked: checked))
        }
        return .list(items: items, ordered: first.ordered, start: first.number)
    }

    /// The lines of one item: deeper-indented lines, blank lines followed by
    /// more of the item, lazy continuations of its paragraph, and everything
    /// inside a fence it opened. They come back with the item's indentation removed.
    private static func itemLines(
        _ marker: ListMarker,
        firstLine: String,
        lines: [String],
        index: inout Int,
        childIndent: Int
    ) -> [String] {
        var body = [firstLine]
        var fence = openingFence(firstLine)
        var afterBlank = false
        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                // Inside a fence the item keeps every line, however it is indented, until the fence closes.
                body.append(stripIndentation(line, columns: marker.contentColumn))
                if closes(open, line) { fence = nil }
            } else if isBlank(line) {
                guard let next = nextNonBlank(lines, after: index),
                      indentation(of: lines[next]) >= childIndent
                else { break }
                body.append("")
                afterBlank = true
            } else if indentation(of: line) >= childIndent {
                let stripped = stripIndentation(line, columns: marker.contentColumn)
                body.append(stripped)
                fence = openingFence(stripped)
                afterBlank = false
            } else if !afterBlank, !startsBlock(lines, at: index) {
                body.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                break
            }
            index += 1
        }
        return body
    }

    /// Builds an item from its lines: a leading paragraph becomes its text, the rest its children.
    private static func listItem(_ lines: [String], checked: Bool?) -> MarkdownListItem {
        let blocks = parse(lines)
        if case .paragraph(let text)? = blocks.first {
            return MarkdownListItem(text: text, checked: checked, children: Array(blocks.dropFirst()))
        }
        return MarkdownListItem(text: "", checked: checked, children: blocks)
    }

    /// `[ ]`, `[x]` or `[X]` at the start of an item, followed by a space or nothing.
    private static func taskState(_ text: String) -> (checked: Bool, rest: String)? {
        let characters = Array(text.prefix(4))
        guard characters.count >= 3, characters[0] == "[", characters[2] == "]" else { return nil }
        let checked: Bool
        switch characters[1] {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        if characters.count == 4, !isIndentation(characters[3]) { return nil }
        return (checked, String(text.dropFirst(3).drop(while: isIndentation)))
    }

    // MARK: Tables

    /// A pipe row followed by a delimiter row such as `|---|:--:|`.
    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let delimiter = lines[index + 1]
        return delimiter.contains("|") && isDelimiterRow(delimiter)
    }

    /// Cells made only of dashes, with an optional colon at either end for alignment.
    private static func isDelimiterRow(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            var marks = Substring(cell)
            if marks.hasPrefix(":") { marks = marks.dropFirst() }
            if marks.hasSuffix(":") { marks = marks.dropLast() }
            return !marks.isEmpty && marks.allSatisfy { $0 == "-" }
        }
    }

    /// A pipe table; rows run until a blank line or a line without a pipe.
    /// Short rows are padded and a long row widens the header, so no cell is lost.
    private static func tableBlock(lines: [String], index: inout Int) -> MarkdownBlock {
        var header = tableCells(lines[index])
        index += 2
        var rows: [[String]] = []
        while index < lines.count, !isBlank(lines[index]), lines[index].contains("|") {
            rows.append(tableCells(lines[index]))
            index += 1
        }
        let width = rows.reduce(header.count) { max($0, $1.count) }
        header += Array(repeating: "", count: width - header.count)
        rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        return .table(header: header, rows: rows)
    }

    /// The trimmed cells of a pipe row. Outer pipes are optional; `\|` stays inside its cell.
    private static func tableCells(_ line: String) -> [String] {
        var content = Substring(line.trimmingCharacters(in: .whitespaces))
        if content.hasPrefix("|") { content = content.dropFirst() }
        if content.hasSuffix("|"), !content.hasSuffix("\\|") { content = content.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in content {
            if character == "|", !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Lines

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func isIndentation(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func nextNonBlank(_ lines: [String], after index: Int) -> Int? {
        var cursor = index + 1
        while cursor < lines.count {
            if !isBlank(lines[cursor]) { return cursor }
            cursor += 1
        }
        return nil
    }

    /// Leading whitespace in columns, a tab advancing to the next multiple of four.
    private static func indentation(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - columns % 4
            } else {
                break
            }
        }
        return columns
    }

    /// Removes up to `columns` columns of leading whitespace. A tab that
    /// straddles the limit leaves its remaining columns as spaces.
    private static func stripIndentation(_ line: String, columns: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < columns {
            let character = line[index]
            if character == " " {
                removed += 1
            } else if character == "\t" {
                let width = 4 - removed % 4
                if removed + width > columns {
                    let leftover = removed + width - columns
                    return String(repeating: " ", count: leftover) + String(line[line.index(after: index)...])
                }
                removed += width
            } else {
                break
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }
}

// MARK: - View

/// Renders Talvo Markdown (issue descriptions, comments, documents) with the
/// app's typography. It sizes to its content, so put it in a `ScrollView`.
struct MarkdownView: View {
    let markdown: String
    var textSize: CGFloat = 13

    var body: some View {
        MarkdownBlocksView(
            blocks: MarkdownParser.blocks(from: markdown),
            style: MarkdownStyle(textSize: textSize)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) for one run
    /// of text. Images become links to the image, bare `http(s)://` URLs become
    /// links, and text the parser rejects comes back exactly as written.
    nonisolated static func inline(_ text: String) -> AttributedString {
        MarkdownInline.attributed(text)
    }
}

/// Fonts and measures for one text size. At the default 13 pt they are the
/// app's own `PortlyTypography`; other sizes keep the same ratios.
private struct MarkdownStyle {
    let textSize: CGFloat

    private var scale: CGFloat { textSize / 13 }
    private var isDefaultSize: Bool { textSize == 13 }

    var bodyFont: Font {
        isDefaultSize ? PortlyTypography.body : .system(size: textSize, weight: .regular, design: .rounded)
    }

    var bodyMediumFont: Font {
        isDefaultSize ? PortlyTypography.bodyMedium : .system(size: textSize, weight: .medium, design: .rounded)
    }

    var codeFont: Font {
        .system(size: 12 * scale, weight: .regular, design: .monospaced)
    }

    var labelFont: Font {
        isDefaultSize ? PortlyTypography.label : .system(size: 10 * scale, weight: .semibold, design: .rounded)
    }

    /// Width of the column a bullet sits in; with the stack spacing, children start 16 pt in.
    var bulletColumn: CGFloat { 10 * scale }
    /// Width of the column numbers are right-aligned in.
    var numberColumn: CGFloat { 20 * scale }
    var checkboxSize: CGFloat { 12 * scale }

    func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return isDefaultSize ? PortlyTypography.title : .system(size: 17 * scale, weight: .semibold, design: .rounded)
        case 2:
            return .system(size: 15 * scale, weight: .semibold, design: .rounded)
        case 3:
            return .system(size: 13.5 * scale, weight: .semibold, design: .rounded)
        default:
            return .system(size: textSize, weight: .semibold, design: .rounded)
        }
    }
}

/// A stack of blocks. Quotes and list items nest it for their own content.
private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                MarkdownBlockView(block: block, style: style)
                    .padding(.top, offset > 0 && block.isSectionHeading ? 6 : 0)
            }
        }
    }
}

/// One block, drawn with the app's typography.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle

    var body: some View {
        switch block {
        case let .heading(level, text):
            MarkdownText(text: text, font: style.headingFont(level: level))
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            MarkdownParagraphView(text: text, style: style)
        case let .list(items, ordered, start):
            MarkdownListView(items: items, ordered: ordered, start: start, style: style)
        case let .code(language, code):
            MarkdownCodeView(language: language, code: code, style: style)
        case let .quote(blocks):
            MarkdownBlocksView(blocks: blocks, style: style)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 2)
                }
                .foregroundStyle(.secondary)
        case .rule:
            Divider()
                .padding(.vertical, 2)
        case let .table(header, rows):
            MarkdownTableView(header: header, rows: rows, style: style)
        }
    }
}

/// One run of inline Markdown: wraps, can be selected, and its links open in the browser.
private struct MarkdownText: View {
    let text: String
    let font: Font

    var body: some View {
        Text(MarkdownView.inline(text))
            .font(font)
            .tint(Color.accentColor)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A paragraph. One that is only an image reads as a file link, with a file glyph in front.
private struct MarkdownParagraphView: View {
    let text: String
    let style: MarkdownStyle

    var body: some View {
        if MarkdownInline.isStandaloneImage(text) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                NucleoIconView(.file, size: style.checkboxSize)
                    .foregroundStyle(.secondary)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                MarkdownText(text: text, font: style.bodyFont)
            }
        } else {
            MarkdownText(text: text, font: style.bodyFont)
        }
    }
}

/// A bullet or numbered list. Nested blocks sit in the item's text column, so
/// a sub-list lines up under its parent's words.
private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let ordered: Bool
    let start: Int
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item, number: start + offset)
                    VStack(alignment: .leading, spacing: 6) {
                        if !item.text.isEmpty || item.children.isEmpty {
                            MarkdownText(text: item.text, font: style.bodyFont)
                        }
                        if !item.children.isEmpty {
                            MarkdownBlocksView(blocks: item.children, style: style)
                        }
                    }
                }
            }
        }
    }

    /// Bullets get a narrow column, unless a task's checkbox needs a little more.
    private var markerWidth: CGFloat {
        if ordered { return style.numberColumn }
        return items.contains { $0.checked != nil } ? style.checkboxSize : style.bulletColumn
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, number: Int) -> some View {
        if let checked = item.checked {
            TaskCheckbox(checked: checked, size: style.checkboxSize)
                .frame(width: markerWidth, alignment: ordered ? .trailing : .leading)
        } else if ordered {
            Text(verbatim: "\(number).")
                .font(style.bodyFont.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: markerWidth, alignment: .trailing)
        } else {
            Text(verbatim: "•")
                .font(style.bodyFont)
                .foregroundStyle(.secondary)
                .frame(width: markerWidth, alignment: .leading)
        }
    }
}

/// The round mark in front of a task item. It shows the state Talvo holds;
/// it is not a control.
private struct TaskCheckbox: View {
    let checked: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if checked {
                NucleoIconView(.checkCircle, size: size)
                    .foregroundStyle(Color.accentColor)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                    .frame(width: size, height: size)
            }
        }
        // Centre the circle on the text's capitals rather than sitting it on the baseline.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.125 }
        .accessibilityElement()
        .accessibilityLabel(checked ? "Done" : "To do")
    }
}

/// A fenced code block: monospaced, scrolls sideways instead of wrapping.
private struct MarkdownCodeView: View {
    let language: String?
    let code: String
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language {
                Text(verbatim: language)
                    .font(style.labelFont)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code.isEmpty ? " " : code)
                    .font(style.codeFont)
                    .textSelection(.enabled)
                    .fixedSize()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A pipe table: header in medium weight, hairlines between rows, cells wrap.
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let style: MarkdownStyle

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    MarkdownText(text: cell, font: style.bodyMediumFont)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        MarkdownText(text: cell, font: style.bodyFont)
                    }
                }
            }
        }
    }
}

private extension MarkdownBlock {
    /// h1 and h2 open a section and get a little more room above them.
    var isSectionHeading: Bool {
        if case let .heading(level, _) = self { return level <= 2 }
        return false
    }
}

// MARK: - Inline

/// Inline Markdown on top of Foundation's parser, with the two things it does
/// not do for us: images as links, and bare URLs as links.
private enum MarkdownInline {
    /// `AttributedString` for one run of inline Markdown, or the raw text if parsing fails.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: imagesAsLinks(text), options: options) else {
            return AttributedString(text)
        }
        linkBareURLs(in: &attributed)
        return attributed
    }

    /// Whether the text is a single `![alt](url)` and nothing else.
    static func isStandaloneImage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), let image = imageSyntax(in: trimmed, at: trimmed.startIndex) else { return false }
        return image.end == trimmed.endIndex
    }

    /// Rewrites `![alt](url)` as `[alt](url)` outside code spans: `Text` cannot
    /// draw the image, so it links to it instead. An empty alt reads "Image".
    private static func imagesAsLinks(_ text: String) -> String {
        guard text.contains("![") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                // An escaped character is copied as is: `\![` is not an image.
                let next = text.index(after: index)
                let end = next < text.endIndex ? text.index(after: next) : next
                output.append(contentsOf: text[index..<end])
                index = end
            } else if character == "`" {
                // A code span is copied as is, whatever it contains.
                let runEnd = text[index...].firstIndex(where: { $0 != "`" }) ?? text.endIndex
                let run = String(text[index..<runEnd])
                let end = text.range(of: run, range: runEnd..<text.endIndex)?.upperBound ?? runEnd
                output.append(contentsOf: text[index..<end])
                index = end
            } else if character == "!", let image = imageSyntax(in: text, at: index) {
                let alt = image.alt.isEmpty ? "Image" : String(image.alt)
                output += "[\(alt)](\(image.destination))"
                index = image.end
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }

    /// The parts of `![alt](destination)`, and where it ends.
    private struct ImageSyntax {
        let alt: Substring
        let destination: Substring
        let end: String.Index
    }

    /// Reads `![alt](destination)` starting at the `!`, or nil when the text there is not one.
    private static func imageSyntax(in text: String, at start: String.Index) -> ImageSyntax? {
        let open = text.index(after: start)
        guard open < text.endIndex, text[open] == "[",
              let closeBracket = matchingClose(in: text, from: open, open: "[", close: "]")
        else { return nil }
        let paren = text.index(after: closeBracket)
        guard paren < text.endIndex, text[paren] == "(",
              let closeParen = matchingClose(in: text, from: paren, open: "(", close: ")")
        else { return nil }
        return ImageSyntax(
            alt: text[text.index(after: open)..<closeBracket],
            destination: text[text.index(after: paren)..<closeParen],
            end: text.index(after: closeParen)
        )
    }

    /// Index of the bracket closing the one at `from`, counting nested pairs and skipping escapes.
    private static func matchingClose(in text: String, from: String.Index, open: Character, close: Character) -> String.Index? {
        var depth = 0
        var index = from
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Links bare `http(s)://` URLs, as GitHub does, leaving code spans and
    /// existing links alone. Only URLs that spell their scheme out count, so
    /// `README.md` stays plain text.
    private static func linkBareURLs(in attributed: inout AttributedString) {
        let plain = String(attributed.characters)
        guard plain.range(of: "http", options: .caseInsensitive) != nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return }
        let matches = detector.matches(in: plain, options: [], range: NSRange(plain.startIndex..., in: plain))
        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let textRange = Range(match.range, in: plain),
                  plain[textRange].lowercased().hasPrefix(scheme + "://"),
                  let range = Range<AttributedString.Index>(match.range, in: attributed)
            else { continue }
            let isTaken = attributed[range].runs.contains { run in
                run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
            }
            if !isTaken {
                attributed[range].link = url
            }
        }
    }
}
