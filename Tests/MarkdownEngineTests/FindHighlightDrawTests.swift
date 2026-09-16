import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Find highlights in prose and tables", .serialized)
@MainActor
struct FindHighlightDrawTests {
    typealias Harness = TableCellEditorTests.Harness

    static let source = "Intro needle here and " + String(repeating: "x", count: 60) + " again.\n\n| A | B |\n|---|---|\n| needle | other |\n\nTail needle."

    private func fragment(at location: Int, in h: Harness) throws -> MarkdownTextLayoutFragment {
        let manager = try #require(h.view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let start = try #require(content.location(manager.documentRange.location, offsetBy: location))
        return try #require(manager.textLayoutFragment(for: start) as? MarkdownTextLayoutFragment)
    }

    @Test func proseMatchesGetOneBubblePerLineAndOnlyTheCurrentOneIsMarked() throws {
        let h = try Harness(Self.source)
        defer { h.close() }
        let text = h.view.string as NSString
        let first = text.range(of: "needle")
        let wrapped = text.range(of: String(repeating: "x", count: 60))
        h.view.setFindHighlights([first, wrapped], current: first)

        let fills = try fragment(at: 0, in: h).findHighlightFills(at: .zero)
        let current = fills.filter(\.isCurrent)
        let others = fills.filter { !$0.isCurrent }
        #expect(current.count == 1)
        #expect(current.first.map { $0.rect.width > 0 && $0.rect.height > 0 } == true)
        #expect(others.count >= 2, "a match wider than the reading column wraps and needs a bubble per line")
        #expect(Set(others.map { $0.rect.minY }).count == others.count, "the wrapped bubbles sit on different lines")
    }

    @Test func tableMatchesAreLeftToTheCellText() throws {
        let h = try Harness(Self.source)
        defer { h.close() }
        let hit = try #require(h.view.tableSearchResults(for: "needle").matches.first)
        h.view.setFindHighlights([hit], current: hit)
        #expect(try fragment(at: h.tableStart, in: h).findHighlightFills(at: .zero).isEmpty)
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let cell = try #require(table.layout.cellText(row: 1, column: 0))
        let marked = h.view.highlightedTableCell(cell, tableRange: table.range, row: 1, column: 0)
        #expect(marked.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
    }

    @Test func proseFragmentDrawingChangesWithHighlightsAndReturnsWhenCleared() throws {
        let h = try Harness(Self.source)
        defer { h.close() }
        let fragment = try fragment(at: 0, in: h)
        func draw() throws -> Data {
            let image = NSImage(size: NSSize(width: 1000, height: 200))
            image.lockFocusFlipped(true)
            NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1000, height: 200)).fill()
            fragment.draw(at: CGPoint(x: h.view.textContainerOrigin.x, y: 0), in: try #require(NSGraphicsContext.current).cgContext)
            image.unlockFocus()
            return try #require(image.tiffRepresentation)
        }
        let before = try draw()
        let hit = (h.view.string as NSString).range(of: "needle")
        h.view.setFindHighlights([hit], current: hit)
        #expect(try draw() != before)
        h.view.setFindHighlights([], current: nil)
        #expect(try draw() == before)
    }

    @Test func revealingTableTextReturnsTheCellRectForTheHostToScroll() throws {
        let head = (0..<20).map { "H\($0)" }.joined(separator: "|")
        let row = (0..<20).map { "value\($0)" }.joined(separator: "|")
        let h = try Harness("Intro\n\n|\(head)|\n|\(String(repeating: "---|", count: 20))\n|\(row)|\n\nTail")
        defer { h.close() }
        let hit = try #require(h.view.tableSearchResults(for: "value19").matches.first)
        let rect = try #require(h.view.revealTableText(in: hit))
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        #expect(table.offset > 0, "the far cell is scrolled into the table's viewport")
        #expect(rect.height > 0 && rect.minY >= table.viewport.minY && rect.maxY <= table.viewport.maxY)
        #expect(h.view.revealTableText(in: (h.view.string as NSString).range(of: "Intro")) == nil)
    }
}
