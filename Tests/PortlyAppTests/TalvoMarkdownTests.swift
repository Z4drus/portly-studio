import AppKit
import Foundation
import SwiftUI
@testable import PortlyApp
import XCTest

/// A Talvo issue as an agent would write it, with every block kind in it.
private let mixedDocument = """
# BLE-42 Markdown in Talvo

Agents write **rich** descriptions with `inline code`, _emphasis_,
~~old ideas~~ and [links](https://talvo.bleeze.ch/issues/BLE-42).

## Steps
1. Parse the blocks
   - headings and paragraphs
   - lists with [x] tasks
2. Render them natively

- [x] Parser written
- [ ] View polished

> **Note**
> Keep it dependency free.

```swift
let view = MarkdownView(markdown: text)
```

| Field | Value |
|-------|:-----:|
| Status | En cours |

***
![Screenshot of the board](https://example.com/board.png)
A trailing paragraph with a stray | pipe
<details>raw html stays as text</details>
"""

final class MarkdownParserTests: XCTestCase {
    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownParser.blocks(from: markdown)
    }

    private func item(_ text: String, checked: Bool? = nil, children: [MarkdownBlock] = []) -> MarkdownListItem {
        MarkdownListItem(text: text, checked: checked, children: children)
    }

    // MARK: Headings and paragraphs

    func testHeadingsOfEveryLevel() {
        let markdown = """
        # One
        ## Two
        ### Three
        #### Four
        ##### Five
        ###### Six
        ## Closed ##
        # C#

        ####### Seven

        #NoSpace
        """

        XCTAssertEqual(parse(markdown), [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 3, text: "Three"),
            .heading(level: 4, text: "Four"),
            .heading(level: 5, text: "Five"),
            .heading(level: 6, text: "Six"),
            .heading(level: 2, text: "Closed"),
            .heading(level: 1, text: "C#"),
            .paragraph("####### Seven"),
            .paragraph("#NoSpace"),
        ])
    }

    func testSoftBreaksJoinAndBlankLinesSplitParagraphs() {
        let markdown = "Hello\nworld\n\nSecond paragraph\n  spans lines\n\n\n\nThird\n"

        XCTAssertEqual(parse(markdown), [
            .paragraph("Hello world"),
            .paragraph("Second paragraph spans lines"),
            .paragraph("Third"),
        ])
        XCTAssertEqual(parse("One\r\nTwo\r\n\r\nThree"), [.paragraph("One Two"), .paragraph("Three")])
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("  \n\t\n"), [])
    }

    func testHardBreaksBecomeNewlines() {
        XCTAssertEqual(
            parse("Line one  \nLine two\\\nLine three\\"),
            [.paragraph("Line one\nLine two\nLine three\\")]
        )
    }

    // MARK: Lists

    func testUnorderedListNestsByIndentation() {
        let markdown = """
        - One
        - Two
          - Two A
          - Two B
            - Deep
        - Three
        """

        XCTAssertEqual(parse(markdown), [
            .list(items: [
                item("One"),
                item("Two", children: [
                    .list(items: [
                        item("Two A"),
                        item("Two B", children: [.list(items: [item("Deep")], ordered: false, start: 1)]),
                    ], ordered: false, start: 1),
                ]),
                item("Three"),
            ], ordered: false, start: 1),
        ])
    }

    func testTabIndentationNestsToo() {
        XCTAssertEqual(parse("* Parent\n\t* Child"), [
            .list(items: [
                item("Parent", children: [.list(items: [item("Child")], ordered: false, start: 1)]),
            ], ordered: false, start: 1),
        ])
    }

    func testOrderedListKeepsItsStartNumberAndNests() {
        let markdown = """
        3. Third
        4. Fourth
           1. Sub one
           2. Sub two
        5. Fifth
        """

        XCTAssertEqual(parse(markdown), [
            .list(items: [
                item("Third"),
                item("Fourth", children: [
                    .list(items: [item("Sub one"), item("Sub two")], ordered: true, start: 1),
                ]),
                item("Fifth"),
            ], ordered: true, start: 3),
        ])
        XCTAssertEqual(parse("1) Alpha\n2) Beta"), [
            .list(items: [item("Alpha"), item("Beta")], ordered: true, start: 1),
        ])
        XCTAssertEqual(parse("1. Step\n  - detail"), [
            .list(items: [
                item("Step", children: [.list(items: [item("detail")], ordered: false, start: 1)]),
            ], ordered: true, start: 1),
        ])
    }

    func testSwitchingBetweenNumbersAndBulletsStartsANewList() {
        XCTAssertEqual(parse("1. a\n- b"), [
            .list(items: [item("a")], ordered: true, start: 1),
            .list(items: [item("b")], ordered: false, start: 1),
        ])
    }

    func testBlankLinesAndContinuationsStayInTheList() {
        XCTAssertEqual(parse("- a\n\n- b"), [
            .list(items: [item("a"), item("b")], ordered: false, start: 1),
        ])
        XCTAssertEqual(parse("- a\n\n  more about a\n- b"), [
            .list(items: [item("a", children: [.paragraph("more about a")]), item("b")], ordered: false, start: 1),
        ])
        XCTAssertEqual(parse("- a\ncontinued lazily"), [
            .list(items: [item("a continued lazily")], ordered: false, start: 1),
        ])
        XCTAssertEqual(parse("- a\n\nAfter the list"), [
            .list(items: [item("a")], ordered: false, start: 1),
            .paragraph("After the list"),
        ])
    }

    func testTaskListItems() {
        let markdown = """
        - [ ] Write tests
        - [x] Ship the parser
        - [X] Shout
        - Plain item
        - [ ]no space
        - [ ]
        """

        XCTAssertEqual(parse(markdown), [
            .list(items: [
                item("Write tests", checked: false),
                item("Ship the parser", checked: true),
                item("Shout", checked: true),
                item("Plain item"),
                item("[ ]no space"),
                item("", checked: false),
            ], ordered: false, start: 1),
        ])
    }

    // MARK: Code

    func testFencedCodeKeepsLanguageAndBody() {
        let markdown = """
        Intro
        ```swift
        let x = 1

        print(x)
        ```
        After
        """

        XCTAssertEqual(parse(markdown), [
            .paragraph("Intro"),
            .code(language: "swift", body: "let x = 1\n\nprint(x)"),
            .paragraph("After"),
        ])
        XCTAssertEqual(parse("~~~ python title=demo\nprint()\n~~~"), [.code(language: "python", body: "print()")])
        XCTAssertEqual(parse("````\n```\ninner\n```\n````"), [.code(language: nil, body: "```\ninner\n```")])
        XCTAssertEqual(parse("  ```\n  a\n    b\n  ```"), [.code(language: nil, body: "a\n  b")])
        XCTAssertEqual(parse("```inline```"), [.paragraph("```inline```")])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(parse("```js\nconst a = 1\n\n# not a heading"), [
            .code(language: "js", body: "const a = 1\n\n# not a heading"),
        ])
    }

    func testFenceInsideAListItemKeepsItsLines() {
        let markdown = """
        - Run:
          ```bash
          pnpm dev
          ```
        - Example
          ```
          a

        b
          ```
        - Done
        """

        XCTAssertEqual(parse(markdown), [
            .list(items: [
                item("Run:", children: [.code(language: "bash", body: "pnpm dev")]),
                item("Example", children: [.code(language: nil, body: "a\n\nb")]),
                item("Done"),
            ], ordered: false, start: 1),
        ])
    }

    // MARK: Quotes and rules

    func testBlockquoteContainingAList() {
        let markdown = """
        > Note
        > - one
        > - two
        >
        > after
        """

        XCTAssertEqual(parse(markdown), [
            .quote([
                .paragraph("Note"),
                .list(items: [item("one"), item("two")], ordered: false, start: 1),
                .paragraph("after"),
            ]),
        ])
        XCTAssertEqual(parse("> outer\n>> inner"), [.quote([.paragraph("outer"), .quote([.paragraph("inner")])])])
        XCTAssertEqual(parse("> quoted\nlazy line"), [.quote([.paragraph("quoted lazy line")])])
    }

    func testRules() {
        XCTAssertEqual(parse("Above\n\n---\n\n***\n\n_ _ _\nBelow"), [
            .paragraph("Above"),
            .rule,
            .rule,
            .rule,
            .paragraph("Below"),
        ])
        // No setext headings: the dashes under a line are a rule of their own.
        XCTAssertEqual(parse("Text\n---"), [.paragraph("Text"), .rule])
    }

    // MARK: Tables

    func testTableWithAlignmentMarkers() {
        let markdown = """
        | Name | Status | Points |
        |:-----|:------:|-------:|
        | BLE-12 | En cours | 3 |
        | BLE-13 | Terminé |  |
        After
        """

        XCTAssertEqual(parse(markdown), [
            .table(
                header: ["Name", "Status", "Points"],
                rows: [["BLE-12", "En cours", "3"], ["BLE-13", "Terminé", ""]]
            ),
            .paragraph("After"),
        ])
    }

    func testRaggedTableKeepsEveryCell() {
        XCTAssertEqual(parse("a | b\n--- | ---\n1 | 2 | 3\n4"), [
            .table(header: ["a", "b", ""], rows: [["1", "2", "3"]]),
            .paragraph("4"),
        ])
        XCTAssertEqual(parse("a | b\nnot a delimiter"), [.paragraph("a | b not a delimiter")])
    }

    // MARK: Whole documents

    func testMixedDocumentLosesNoText() {
        let blocks = parse(mixedDocument)

        XCTAssertEqual(
            blocks.map { kind(of: $0) },
            ["heading", "paragraph", "heading", "list", "list", "quote", "code", "table", "rule", "paragraph"]
        )
        let rendered = " " + words(allText(blocks).joined(separator: " ")) + " "
        for line in mixedDocument.components(separatedBy: "\n") {
            let expected = words(line)
            guard !expected.isEmpty else { continue }
            XCTAssertTrue(rendered.contains(" \(expected) "), "Lost text from line: \(line)")
        }
    }

    /// Words of two letters or more, in order, so markup characters and list numbers do not count.
    private func words(_ text: String) -> String {
        text.split(whereSeparator: { !$0.isLetter })
            .filter { $0.count >= 2 }
            .joined(separator: " ")
    }

    /// Every piece of text the blocks hold, in document order.
    private func allText(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case let .heading(_, text), let .paragraph(text):
                return [text]
            case let .list(items, _, _):
                return items.flatMap { [$0.text] + allText($0.children) }
            case let .code(language, body):
                return [language ?? "", body]
            case let .quote(inner):
                return allText(inner)
            case .rule:
                return []
            case let .table(header, rows):
                return header + rows.flatMap { $0 }
            }
        }
    }

    private func kind(of block: MarkdownBlock) -> String {
        switch block {
        case .heading: return "heading"
        case .paragraph: return "paragraph"
        case .list: return "list"
        case .code: return "code"
        case .quote: return "quote"
        case .rule: return "rule"
        case .table: return "table"
        }
    }
}

/// Inline rendering, and the whole view hosted in AppKit so a layout that
/// throws or collapses is caught here rather than in the issue panel.
@MainActor
final class MarkdownViewTests: XCTestCase {
    func testInlineDropsMarkupAndKeepsText() {
        XCTAssertEqual(String(MarkdownView.inline("**a** `b`").characters), "a b")
    }

    func testInlineMarksBoldCodeAndStrikethrough() {
        let intents = MarkdownView.inline("**bold** `code` ~~gone~~").runs.compactMap { $0.inlinePresentationIntent }

        XCTAssertTrue(intents.contains { $0.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.code) })
        XCTAssertTrue(intents.contains { $0.contains(.strikethrough) })
    }

    func testInlineLinkCarriesItsURL() {
        let text = MarkdownView.inline("See [BLE-42](https://talvo.bleeze.ch/issues/BLE-42)")

        XCTAssertEqual(String(text.characters), "See BLE-42")
        XCTAssertEqual(text.runs.compactMap { $0.link?.absoluteString }, ["https://talvo.bleeze.ch/issues/BLE-42"])
    }

    func testImageBecomesALinkToTheImage() {
        let text = MarkdownView.inline("![Board](https://example.com/board.png)")

        XCTAssertEqual(String(text.characters), "Board")
        XCTAssertEqual(text.runs.compactMap { $0.link?.absoluteString }, ["https://example.com/board.png"])
        XCTAssertEqual(String(MarkdownView.inline("![](https://example.com/a.png)").characters), "Image")
        XCTAssertEqual(String(MarkdownView.inline("`![x](y)`").characters), "![x](y)")
    }

    func testBareURLsBecomeLinksOutsideCode() {
        let text = MarkdownView.inline("Preview: https://talvo.bleeze.ch/issues/BLE-42.")

        XCTAssertEqual(String(text.characters), "Preview: https://talvo.bleeze.ch/issues/BLE-42.")
        XCTAssertEqual(text.runs.compactMap { $0.link?.absoluteString }, ["https://talvo.bleeze.ch/issues/BLE-42"])
        XCTAssertTrue(MarkdownView.inline("`https://example.com`").runs.allSatisfy { $0.link == nil })
        XCTAssertTrue(MarkdownView.inline("Open README.md").runs.allSatisfy { $0.link == nil })
    }

    func testMixedDocumentLaysOut() {
        let host = NSHostingView(rootView: MarkdownView(markdown: mixedDocument).frame(width: 420))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 800)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.height, 150)
    }
}
