//
//  TableCellTests.swift
//  MarkdownEngineTests
//
//  Table cells reuse the shared `InlineParser` (one parser, one truth) instead
//  of a separate regex re-implementation — so a cell formats identically to
//  body text, including nested emphasis the old per-cell regexes could not do.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table cell inline formatting")
struct TableCellTests {

    private func cell(_ raw: String, header: Bool = false) -> NSAttributedString {
        _ = NSApplication.shared
        let cfg = MarkdownEditorConfiguration.default
        return MarkdownStyler.formattedCellString(
            raw, baseFont: NSFont.systemFont(ofSize: 14), header: header,
            theme: cfg.theme, codeBackgroundColor: .clear, latex: cfg.services.latex,
            extensions: [HighlightExtension(), StrikethroughExtension()]
        )
    }

    /// Symbolic traits of the font on the first occurrence of `ch` in the
    /// (marker-stripped) rendered string.
    private func traits(_ s: NSAttributedString, _ ch: Character) -> NSFontDescriptor.SymbolicTraits {
        let ns = s.string as NSString
        let idx = ns.range(of: String(ch)).location
        guard idx != NSNotFound,
              let font = s.attribute(.font, at: idx, effectiveRange: nil) as? NSFont else { return [] }
        return font.fontDescriptor.symbolicTraits
    }

    /// A cell used to draw the whole `[text](url)` source, so one long URL decided the
    /// column width and pushed everything after it out of view.
    @Test func linkShowsItsLabelInLinkColor() {
        let s = cell("[BingogoSSD auf eBay.de](https://www.ebay.de/itm/358654760269)")
        #expect(s.string == "BingogoSSD auf eBay.de")
        let color = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == MarkdownEditorConfiguration.default.theme.link)
    }

    @Test func linkLabelKeepsItsInlineFormatting() {
        let s = cell("[**bold** label](https://example.com/a/very/long/path/that/would/dominate)")
        #expect(s.string == "bold label")
        #expect(traits(s, "b").contains(.bold))
    }

    @Test func emptyLinkLabelFallsBackToItsSource() {
        let s = cell("[](https://example.com)")
        #expect(s.string == "[](https://example.com)")
    }

    @Test func wikiLinkShowsItsNameWithoutTheTarget() {
        let s = cell("[[Angebot|8f2c1d9e-4b7a]]")
        #expect(s.string == "Angebot")
        let color = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == MarkdownEditorConfiguration.default.theme.link)
    }

    /// Images stay raw: a cell rasterizes at a fixed width and has no place to size one.
    @Test func imageKeepsItsSourceInACell() {
        let s = cell("![Diagramm](https://example.com/plan.png)")
        #expect(s.string == "![Diagramm](https://example.com/plan.png)")
    }

    @Test func plainCellHasNoEmphasis() {
        let s = cell("hello")
        #expect(s.string == "hello")
        #expect(!traits(s, "h").contains(.bold))
        #expect(!traits(s, "h").contains(.italic))
    }

    @Test func boldItalicStripMarkers() {
        #expect(cell("a **b** c").string == "a b c")
        #expect(traits(cell("a **b** c"), "b").contains(.bold))
        #expect(traits(cell("a *b* c"), "b").contains(.italic))
        #expect(traits(cell("***z***"), "z").contains(.bold))
        #expect(traits(cell("***z***"), "z").contains(.italic))
    }

    @Test func inlineCodeGetsCodeBackground() {
        let s = cell("`x`")
        #expect(s.string == "x")
        #expect(s.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
    }

    @Test func strikethroughIsApplied() {
        let s = cell("~~gone~~")
        #expect(s.string == "gone")
        #expect(s.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil)
    }

    @Test func highlightIsApplied() {
        let s = cell("==note==")
        #expect(s.string == "note")
        #expect(s.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
    }

    @Test func headerCellStartsBold() {
        #expect(traits(cell("h", header: true), "h").contains(.bold))
    }

    /// The headline win: the old per-cell regex `\*\*([^*]+)\*\*` cannot match
    /// emphasis nested inside emphasis (the `[^*]+` stops at the inner `*`), so
    /// `**a *b* c**` left `a`/`c` unbolded. The shared InlineParser composes to
    /// any depth.
    @Test func nestedEmphasisComposesToAnyDepth() {
        let s = cell("**a *b* c**")
        #expect(traits(s, "a").contains(.bold))
        #expect(!traits(s, "a").contains(.italic))
        #expect(traits(s, "b").contains(.bold))
        #expect(traits(s, "b").contains(.italic))
        #expect(traits(s, "c").contains(.bold))
    }
}
