import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Auto-links")
struct AutoLinkTests {
    private func linkRanges(in text: String) -> [NSRange] {
        MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14
        ).filter { $0.attributes[.link] != nil }.map(\.range)
    }

    // GFM auto-links are scheme URLs, `www.` hosts, and e-mail addresses. A bare
    // domain in running text stays text — which also lets the styler skip the
    // data detector for paragraphs without `://`, `www.`, or `@`.
    @MainActor
    @Test func schemeWwwAndEmailAreLinkedButBareDomainIsNot() {
        _ = NSApplication.shared
        let text = "see https://example.com and www.example.org or me@example.net but not example.com alone\n"
        let ns = text as NSString
        let ranges = linkRanges(in: text)

        for expected in ["https://example.com", "www.example.org", "me@example.net"] {
            let r = ns.range(of: expected)
            #expect(ranges.contains { NSIntersectionRange($0, r).length == r.length }, "\(expected) must be auto-linked")
        }
        let bare = ns.range(of: "example.com alone")
        #expect(!ranges.contains { NSIntersectionRange($0, bare).length > 0 }, "a bare domain must stay text")
    }

    @MainActor
    @Test func paragraphWithoutLinkMarkersEmitsNoLinks() {
        _ = NSApplication.shared
        #expect(linkRanges(in: "Ein Absatz mit Punkt. Und noch einem, z.B. so.\n").isEmpty)
    }
}
