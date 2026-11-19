//
//  CodeBlockCopyTests.swift
//  MarkdownEngine
//
//  Copying out of a fenced code block must give the code, not Markdown: the
//  fence lines are hidden while the caret is outside the block, so a drag over
//  the visible block picks them up, and code lines rendered as Markdown turn
//  `# comment` into a heading and run the lines together in rich targets.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Copying code out of fenced blocks")
struct CodeBlockCopyTests {
    let source = "Intro\n\n```bash\n# install\nbrew install uv\nuv sync\n```\n\nTail\n"

    func range(of text: String) -> NSRange {
        (source as NSString).range(of: text)
    }

    func copied(_ selection: NSRange) -> MarkdownPasteboardWriter.CopiedText {
        MarkdownPasteboardWriter.copiedText(selection, in: source)
    }

    @Test func wholeBlockIncludingHiddenFencesCopiesOnlyTheCode() {
        let block = range(of: "```bash\n# install\nbrew install uv\nuv sync\n```")
        let result = copied(block)
        #expect(result.plain == "# install\nbrew install uv\nuv sync")
        #expect(result.rich == "```bash\n# install\nbrew install uv\nuv sync\n```")
    }

    @Test func linesInsideTheBlockStayCodeInRichFlavors() {
        let lines = range(of: "# install\nbrew install uv")
        let result = copied(lines)
        #expect(result.plain == "# install\nbrew install uv")
        #expect(result.rich == "```bash\n# install\nbrew install uv\n```")
    }

    @Test func selectionAcrossProseAndCodeKeepsTheMarkdown() {
        let start = range(of: "Intro").location
        let end = NSMaxRange(range(of: "brew install uv"))
        let result = copied(NSRange(location: start, length: end - start))
        #expect(result.plain == "Intro\n\n```bash\n# install\nbrew install uv")
        #expect(result.rich == "Intro\n\n```bash\n# install\nbrew install uv\n```")
    }

    @Test func selectionStartingInsideTheBlockReopensItsFence() {
        let start = range(of: "uv sync").location
        let end = NSMaxRange(range(of: "Tail"))
        let result = copied(NSRange(location: start, length: end - start))
        #expect(result.plain == "uv sync\n```\n\nTail")
        #expect(result.rich == "```bash\nuv sync\n```\n\nTail")
    }

    @Test func proseOnlySelectionIsUnchanged() {
        let result = copied(range(of: "Intro"))
        #expect(result.plain == "Intro")
        #expect(result.rich == "Intro")
    }

    @Test func richFlavorsRenderCodeAsPreformattedText() throws {
        let result = copied(range(of: "# install\nbrew install uv"))
        let html = MarkdownHTMLRenderer.html(from: result.rich)
        #expect(html.contains("<pre>"))
        #expect(!html.contains("<h1"))
        #expect(html.contains("# install\nbrew install uv"))
    }

    @Test @MainActor func copyCommandWritesCodeOnlyAsPlainText() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("CodeBlockCopyTests.copy"))
        let block = range(of: "```bash\n# install\nbrew install uv\nuv sync\n```")
        MarkdownPasteboardWriter.write(selection: block, of: source, to: pb)
        #expect(pb.string(forType: .string) == "# install\nbrew install uv\nuv sync")
        #expect(pb.string(forType: MarkdownPasteboardWriter.markdownType) == (source as NSString).substring(with: block))
        let html = try #require(pb.string(forType: .html))
        #expect(html.contains("<pre>"))
        #expect(!html.contains("<h1"))
    }
}
