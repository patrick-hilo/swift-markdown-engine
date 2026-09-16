//
//  TableAccessibilityTests.swift
//  MarkdownEngine
//
//  Tables drawn as text reach VoiceOver through accessibility elements the
//  text view owns and builds from the same geometry the fragment draws with:
//  one table per rendered table, rows of cells, a text element per cell, each
//  framed on screen where it is drawn and stable across queries.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Table accessibility", .serialized)
@MainActor
struct TableAccessibilityTests {

    /// A wide table (12 columns will not fit in 520 points) and a narrow one.
    private static let source = """
    Intro paragraph.

    | \((1...12).map { "column \($0) heading" }.joined(separator: " | ")) |
    |\(String(repeating: "---|", count: 12))
    | \((1...12).map { "body cell \($0)" }.joined(separator: " | ")) |

    Between the tables.

    | alpha | beta |
    |---|---|
    | one | **two** |

    Trailing paragraph.
    """

    /// `NSTextLayoutManager.delegate` is weak; the harness has to own it.
    @MainActor private static var layoutDelegates: [MarkdownLayoutManagerDelegate] = []

    private struct Harness {
        let window: NSWindow
        let stack: HeightBehaviorStack
        let textView: NativeTextView
        /// `NativeTextView.layoutBridge` is weak; the harness has to own it.
        let bridge: LayoutBridge

        func close() { window.orderOut(nil) }
    }

    private func makeHarness(viewportHeight: CGFloat = 900) throws -> Harness {
        _ = NSApplication.shared
        let width: CGFloat = 520
        let stack = HeightBehaviorStack(viewport: NSSize(width: width, height: viewportHeight))
        let tv = stack.textView
        let tlm = try #require(tv.textLayoutManager)
        let delegate = MarkdownLayoutManagerDelegate()
        Self.layoutDelegates.append(delegate)
        tlm.delegate = delegate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: viewportHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = stack.scrollView
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderBack(nil)

        tv.string = Self.source
        let bridge = LayoutBridge(tlm)
        tv.layoutBridge = bridge
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: "Helvetica", fontSize: 15, configuration: .default
        )
        TextStylingService.restyle(
            textView: tv,
            layoutBridge: bridge,
            paragraphCandidates: [NSRange(location: 0, length: (Self.source as NSString).length)],
            baseFont: font,
            paragraphStyle: style,
            caretLocation: (Self.source as NSString).length,
            activeTokenIndices: [],
            wikiLinkIDProvider: { _ in nil }
        )
        tlm.ensureLayout(for: try #require(tlm.textContentManager).documentRange)
        return Harness(window: window, stack: stack, textView: tv, bridge: bridge)
    }

    private func tables(of tv: NativeTextView) -> [TableAccessibilityElement] {
        (tv.accessibilityChildren() ?? []).compactMap { $0 as? TableAccessibilityElement }
    }

    private func rows(_ table: TableAccessibilityElement) -> [TableAccessibilityElement] {
        table.accessibilityChildren() as? [TableAccessibilityElement] ?? []
    }

    private func cells(_ row: TableAccessibilityElement) -> [TableAccessibilityElement] {
        row.accessibilityChildren() as? [TableAccessibilityElement] ?? []
    }

    private func value(_ element: TableAccessibilityElement) -> String? {
        element.accessibilityValue() as? String
    }

    @Test func theVisibleTablesAreExposedAsAccessibilityTables() throws {
        let h = try makeHarness()
        defer { h.close() }
        let tables = tables(of: h.textView)
        #expect(tables.count == 2)
        #expect(tables.allSatisfy { $0.accessibilityRole() == .table })
        let wide = try #require(tables.first)
        #expect(wide.accessibilityRowCount() == 2)
        #expect(wide.accessibilityColumnCount() == 12)
        #expect(rows(wide).count == 2)
        #expect(rows(wide).allSatisfy { $0.accessibilityRole() == .row })
        #expect(rows(wide).map { $0.accessibilityIndex() } == [0, 1])
        let narrow = try #require(tables.last)
        let narrowBody = try #require(rows(narrow).last)
        #expect(cells(narrowBody).count == 2)
        #expect(cells(narrowBody).allSatisfy { $0.accessibilityRole() == .cell })
        #expect(h.textView.accessibilityChildrenInNavigationOrder()?.contains { $0 === narrow } == true)
    }

    @Test func theTreeIsOwnedByTheTextViewAndChainsBackToIt() throws {
        let h = try makeHarness()
        defer { h.close() }
        let narrow = try #require(tables(of: h.textView).last)
        let body = try #require(rows(narrow).last)
        let cell = try #require(cells(body).first)
        let text = try #require(cell.accessibilityChildren()?.first as? TableAccessibilityElement)
        #expect(text.accessibilityRole() == .staticText)
        #expect(text.accessibilityParent() as? TableAccessibilityElement === cell)
        #expect(cell.accessibilityParent() as? TableAccessibilityElement === body)
        #expect(body.accessibilityParent() as? TableAccessibilityElement === narrow)
        #expect(narrow.accessibilityParent() as? NativeTextView === h.textView)
        #expect((narrow.accessibilityRows() as? [TableAccessibilityElement])?.count == 2)
        #expect(narrow.accessibilityRows()?.first as? TableAccessibilityElement === rows(narrow).first)

        // The same objects come back on the next query: VoiceOver holds them by identity.
        let again = try #require(tables(of: h.textView).last)
        #expect(again === narrow)
        #expect(cells(try #require(rows(again).last)).first === cell)
    }

    @Test func cellsCarryTheirFormattedTextTheirHeaderAndTheirScreenFrame() throws {
        let h = try makeHarness()
        defer { h.close() }
        let narrow = try #require(tables(of: h.textView).last)
        let header = try #require(rows(narrow).first)
        let body = try #require(rows(narrow).last)
        let two = try #require(cells(body).last)
        #expect(value(two) == "two", "markers are stripped, the reader hears the text")
        #expect(value(try #require(two.accessibilityChildren()?.first as? TableAccessibilityElement)) == "two")
        #expect(two.accessibilityColumnIndexRange() == NSRange(location: 1, length: 1))
        #expect(two.accessibilityRowIndexRange() == NSRange(location: 1, length: 1))
        let beta = try #require(cells(header).last)
        #expect(value(beta) == "beta")
        #expect(two.accessibilityColumnHeaderUIElements()?.first as? TableAccessibilityElement === beta)
        #expect((narrow.accessibilityColumnHeaderUIElements() as? [TableAccessibilityElement])?.count == 2)

        let rendered = try #require(h.textView.renderedTable(at: Self.narrowTableLocation))
        let drawn = try #require(rendered.cell(row: 1, column: 1))
        let expected = h.window.convertToScreen(h.textView.convert(drawn.rect, to: nil))
        #expect(abs(two.accessibilityFrame().minX - expected.minX) < 0.5)
        #expect(abs(two.accessibilityFrame().minY - expected.minY) < 0.5)
        #expect(abs(two.accessibilityFrame().width - expected.width) < 0.5)
        #expect(narrow.accessibilityFrame().contains(two.accessibilityFrame()))

        // Independent of the rendered geometry: the grid reads left to right
        // and, on a screen whose y grows upwards, the header sits above the body.
        let one = try #require(cells(body).first)
        #expect(one.accessibilityFrame().maxX <= two.accessibilityFrame().minX + 0.5)
        #expect(beta.accessibilityFrame().minY >= two.accessibilityFrame().maxY - 0.5)
        #expect(one.accessibilityFrame().width > 10 && one.accessibilityFrame().height > 10)
    }

    @Test func aScreenPointHitTestsToTheCellTextUnderIt() throws {
        let h = try makeHarness()
        defer { h.close() }
        let narrow = try #require(tables(of: h.textView).last)
        let body = try #require(rows(narrow).last)
        let one = try #require(cells(body).first)
        let centre = NSPoint(x: one.accessibilityFrame().midX, y: one.accessibilityFrame().midY)
        let hit = try #require(h.textView.accessibilityHitTest(centre) as? TableAccessibilityElement)
        #expect(hit.accessibilityRole() == .staticText)
        #expect(value(hit) == "one")
        let outside = NSPoint(x: narrow.accessibilityFrame().minX - 40, y: narrow.accessibilityFrame().minY - 40)
        #expect(h.textView.accessibilityHitTest(outside) as? TableAccessibilityElement == nil)
    }

    @Test func aScrolledWideTableExposesOnlyTheCellsInItsBoxAndKeepsItsElements() throws {
        let h = try makeHarness()
        defer { h.close() }
        let before = try #require(tables(of: h.textView).first)
        let wideTable = try #require(h.textView.renderedTable(at: Self.wideTableLocation))
        let sourceID = try #require(wideTable.sourceID)
        let bodyBefore = try #require(rows(before).last)
        let unscrolledCells = cells(bodyBefore)
        #expect(unscrolledCells.first.flatMap(value) == "body cell 1")
        #expect(unscrolledCells.count < 12, "twelve columns do not fit the box, the rest is clipped away")
        let frameBefore = try #require(unscrolledCells.last).accessibilityFrame()
        h.textView.tableHorizontalScrollOffsets[sourceID] = wideTable.layout.columnLeft[3]

        // Three columns scroll out on the left and as many come in on the
        // right: the visible cells change, the elements stay the same objects
        // and report their new place.
        let after = try #require(tables(of: h.textView).first)
        #expect(after === before)
        let bodyAfter = try #require(rows(after).last)
        let scrolledCells = cells(bodyAfter)
        let values = scrolledCells.compactMap(value)
        #expect(values.first == "body cell 4")
        #expect(!values.contains("body cell 1"), "a cell scrolled out of the box is not exposed")
        #expect(scrolledCells.allSatisfy { after.accessibilityFrame().minX <= $0.accessibilityFrame().minX + 0.5 })
        let lastBefore = try #require(unscrolledCells.last)
        #expect(scrolledCells.contains { $0 === lastBefore })
        #expect(lastBefore.accessibilityFrame().minX < frameBefore.minX - 10, "the same element moved left with the scroll")
    }

    @Test func onlyTablesInTheViewportAreExposed() throws {
        let h = try makeHarness(viewportHeight: 160)
        defer { h.close() }
        let wide = try #require(h.textView.renderedTable(at: Self.wideTableLocation))
        #expect(tables(of: h.textView).map(\.tableLocation) == [Self.wideTableLocation])

        let clip = h.stack.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: wide.viewport.maxY + 4))
        h.stack.scrollView.reflectScrolledClipView(clip)
        let scrolled = tables(of: h.textView).map(\.tableLocation)
        #expect(!scrolled.contains(Self.wideTableLocation), "the wide table is above the viewport now")
        #expect(scrolled == [Self.narrowTableLocation])
    }

    @Test func rawSourceModeExposesNoTables() throws {
        let h = try makeHarness()
        defer { h.close() }
        var raw = h.textView.configuration
        raw.rawSourceMode = true
        h.textView.configuration = raw
        #expect(tables(of: h.textView).isEmpty)
    }

    private static var wideTableLocation: Int {
        ((source as NSString).range(of: "| column 1 heading")).location
    }

    private static var narrowTableLocation: Int {
        ((source as NSString).range(of: "| alpha")).location
    }
}
