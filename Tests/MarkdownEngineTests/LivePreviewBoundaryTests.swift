import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Live preview construct boundaries")
struct LivePreviewBoundaryTests {
    private func storage(_ source: String, caret: Int) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14)
        let result = NSMutableAttributedString(string: source, attributes: [.font: font])
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: source, fontName: font.fontName, fontSize: 14, caretLocation: caret
        ) {
            result.addAttributes(attributes, range: range)
        }
        return result
    }

    private func hidden(_ storage: NSAttributedString, at index: Int) -> Bool {
        (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize ==
            MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize
    }

    @Test(arguments: [
        "**outer *inner* tail**",
        "**outer [inner](target.md) tail**",
        "[outer *inner* tail](target.md)",
        "**outer `inner` tail**"
    ])
    func outerContentDoesNotRevealUnrelatedInnerSyntax(_ source: String) {
        let ns = source as NSString
        let inner = ns.range(of: "inner")
        let outer = ns.range(of: "outer")
        let styled = storage(source, caret: outer.location + 1)
        #expect(!hidden(styled, at: 0))
        #expect(hidden(styled, at: inner.location - 1))
        #expect(styled.string == source)
    }

    @Test(arguments: [
        "**outer *inner* tail**",
        "**outer [inner](target.md) tail**",
        "[outer *inner* tail](target.md)",
        "**outer `inner` tail**"
    ])
    func innerCaretRevealsContainingConstructs(_ source: String) {
        let ns = source as NSString
        let inner = ns.range(of: "inner")
        let styled = storage(source, caret: inner.location + 1)
        #expect(!hidden(styled, at: 0))
        #expect(!hidden(styled, at: inner.location - 1))
        #expect(styled.string == source)
    }

    @Test
    func siblingConstructsStayCollapsedWithUTF16Offsets() {
        let source = "😀 **outer *first* and *second* tail** after"
        let ns = source as NSString
        let first = ns.range(of: "first")
        let second = ns.range(of: "second")
        let styled = storage(source, caret: first.location + 1)
        #expect(!hidden(styled, at: ns.range(of: "**").location))
        #expect(!hidden(styled, at: first.location - 1))
        #expect(hidden(styled, at: second.location - 1))
        #expect(styled.length == ns.length)
        #expect(styled.string == source)
    }

    @Test(arguments: ["# heading **one** and *two*\n", "- item **one** and *two*\n", "- [ ] item **one** and *two*\n", "1. item **one** and *two*\n"])
    func blockContentRetainsLocalInlineReveal(_ source: String) {
        let ns = source as NSString
        let one = ns.range(of: "one")
        let two = ns.range(of: "two")
        let styled = storage(source, caret: one.location + 1)
        #expect(!hidden(styled, at: one.location - 1))
        #expect(hidden(styled, at: two.location - 1))
        #expect(styled.string == source)
    }

    @Test(arguments: ["*unfinished", "[unfinished](target", "![unfinished", "`unfinished"])
    func malformedInlineSourceRemainsVisible(_ source: String) {
        let styled = storage(source, caret: -1)
        for index in 0..<styled.length {
            #expect(!hidden(styled, at: index))
            let color = styled.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            #expect(color?.alphaComponent != 0)
        }
        #expect(styled.string == source)
    }
}
