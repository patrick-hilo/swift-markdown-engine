import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Rendered table selection and search", .serialized)
@MainActor
struct TableTextInteractionTests {
    typealias Harness = TableCellEditorTests.Harness

    func event(_ type: NSEvent.EventType, point: CGPoint, h: Harness) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: h.view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func point(_ table: RenderedTable, row: Int, column: Int, end: Bool = false) throws -> CGPoint {
        let rect = try #require(table.layout.cellTextRect(row: row, column: column))
        return CGPoint(x: min(table.viewport.maxX - 0.1, table.viewport.minX - table.offset + (end ? rect.maxX : rect.minX)),
                       y: table.viewport.minY + rect.minY + 3)
    }

    @Test func mouseDragCopiesRenderedCellsAndContextMenuUsesCopy() throws {
        let source = "Intro\n\n|A|B|\n|-|-|\n|**😀 a**|`b \\| c`|\n\nTail"
        let h = try Harness(source)
        defer { h.close() }
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let start = try point(table, row: 1, column: 0)
        let end = try point(table, row: 1, column: 1, end: true)
        h.view.mouseDown(with: try event(.leftMouseDown, point: start, h: h))
        #expect(h.view.tableCellEditor == nil)
        h.view.mouseDragged(with: try event(.leftMouseDragged, point: end, h: h))
        h.view.mouseUp(with: try event(.leftMouseUp, point: end, h: h))
        #expect(h.view.validTableSelection()?.text == "😀 a\tb | c")
        #expect(h.window.firstResponder === h.view)
        #expect(NSApp.sendAction(#selector(NSText.copy(_:)), to: h.window.firstResponder, from: nil))
        #expect(NSPasteboard.general.string(forType: .string) == "😀 a\tb | c")
        let menu = try #require(h.view.menu(for: try event(.rightMouseDown, point: start, h: h)))
        #expect(menu.items.contains { $0.action == #selector(NSText.copy(_:)) })
        #expect(h.view.string == source)
        #expect(h.view.undoManager?.canUndo == false)
    }

    @Test func partialReverseDragCopiesOnlySelectedCharacters() throws {
        let h = try Harness("Intro\n\n|A|B|\n|-|-|\n|abcdef|other|\n\nTail")
        defer { h.close() }
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let cell = try #require(table.layout.cellText(row: 1, column: 0))
        let rect = try #require(table.layout.cellTextRect(row: 1, column: 0))
        func at(_ count: Int) -> CGPoint {
            let width = cell.attributedSubstring(from: NSRange(location: 0, length: count)).size().width
            return CGPoint(x: table.viewport.minX - table.offset + rect.minX + width, y: table.viewport.minY + rect.minY + 3)
        }
        h.view.mouseDown(with: try event(.leftMouseDown, point: at(4), h: h))
        h.view.mouseDragged(with: try event(.leftMouseDragged, point: at(1), h: h))
        h.view.mouseUp(with: try event(.leftMouseUp, point: at(1), h: h))
        #expect(h.view.validTableSelection()?.text == "bcd")
    }

    @Test func fragmentDrawingIncludesFindHighlights() throws {
        let h = try Harness()
        defer { h.close() }
        let manager = try #require(h.view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(manager.documentRange.location, offsetBy: h.tableStart))
        let fragment = try #require(manager.textLayoutFragment(for: location))
        func draw() -> Data? {
            let image = NSImage(size: NSSize(width: 1000, height: 300))
            image.lockFocusFlipped(true)
            NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1000, height: 300)).fill()
            fragment.draw(at: CGPoint(x: h.view.textContainerOrigin.x, y: 0), in: NSGraphicsContext.current!.cgContext)
            image.unlockFocus()
            return image.tiffRepresentation
        }
        let before = try #require(draw())
        let hit = try #require(h.view.tableSearchResults(for: "old").matches.first)
        h.view.setTableFindHighlights([hit], current: hit)
        let after = try #require(draw())
        #expect(before != after)
        h.view.setTableFindHighlights([], current: nil)
        #expect(draw() == before)
    }

    @Test(arguments: [false, true]) func heldPointerContinuesScrollingBothAxesAndStopsOnRelease(cancelWithEscape: Bool) throws {
        let header = (0..<20).map { "column\($0)" }.joined(separator: "|")
        let row = (0..<20).map { "value\($0)" }.joined(separator: "|")
        let source = "Intro\n\n|\(header)|\n|\(String(repeating: "---|", count: 20))\n" + String(repeating: "|\(row)|\n", count: 50) + "\nTail"
        let h = try Harness(source)
        defer { h.close() }
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        h.view.baseContentHeight = table.viewport.maxY + 100
        h.view.applyManagedFrameSize(width: 1000)
        let start = try point(table, row: 1, column: 0)
        let edge = CGPoint(x: table.viewport.maxX + 2, y: h.view.visibleRect.maxY - 2)
        h.view.mouseDown(with: try event(.leftMouseDown, point: start, h: h))
        let held = try event(.leftMouseDragged, point: edge, h: h)
        h.view.mouseDragged(with: held)
        let initialX = h.view.renderedTable(at: h.tableStart)?.offset ?? 0
        let initialY = h.stack.scrollView.contentView.bounds.minY
        let initialSelection = h.view.selectedRange().length
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect((h.view.renderedTable(at: h.tableStart)?.offset ?? 0) > initialX)
        #expect(h.stack.scrollView.contentView.bounds.minY > initialY)
        #expect(h.view.selectedRange().length > initialSelection)
        let scrolledX = h.view.renderedTable(at: h.tableStart)?.offset ?? 0
        let scrolledY = h.stack.scrollView.contentView.bounds.minY
        let returnEdge = CGPoint(x: table.viewport.minX - 2, y: h.view.visibleRect.minY + 2)
        h.view.mouseDragged(with: try event(.leftMouseDragged, point: returnEdge, h: h))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect((h.view.renderedTable(at: h.tableStart)?.offset ?? 0) < scrolledX)
        #expect(h.stack.scrollView.contentView.bounds.minY < scrolledY)
        if cancelWithEscape {
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: h.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            h.view.keyDown(with: escape)
        } else { h.view.mouseUp(with: held) }
        #expect(h.view.tableDragTimer == nil)
        #expect(h.view.tablePointer == nil)
        let after = h.stack.scrollView.contentView.bounds.origin
        let selected = h.view.selectedRange()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(h.stack.scrollView.contentView.bounds.origin == after)
        #expect(h.view.selectedRange() == selected)
        #expect(h.view.string == source)
    }

    @Test func rawPresentationCannotCopyAnOldRenderedSelection() throws {
        let source = "Intro\n\n|A|B|\n|-|-|\n|**one**|two|\n\nTail"
        let h = try Harness(source)
        defer { h.close() }
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let start = try point(table, row: 1, column: 0), end = try point(table, row: 1, column: 1, end: true)
        h.view.mouseDown(with: try event(.leftMouseDown, point: start, h: h))
        h.view.mouseDragged(with: try event(.leftMouseDragged, point: end, h: h))
        h.view.mouseUp(with: try event(.leftMouseUp, point: end, h: h))
        #expect(h.view.validTableSelection()?.text == "one\ttwo")
        let selected = h.view.selectedRange()
        h.view.configuration.rawSourceMode = true
        h.coordinator.configuration.rawSourceMode = true
        h.coordinator.rebuildTextStorageAndStyle(h.view, from: source)
        h.view.setSelectedRange(selected)
        h.view.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == (source as NSString).substring(with: selected))
        #expect(h.view.validTableSelection() == nil)
    }

    @Test func clickOpensCellOnlyAfterMouseUp() throws {
        let h = try Harness()
        defer { h.close() }
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let p = try point(table, row: 1, column: 0)
        h.view.mouseDown(with: try event(.leftMouseDown, point: p, h: h))
        #expect(h.view.tableCellEditor == nil)
        h.view.mouseUp(with: try event(.leftMouseUp, point: p, h: h))
        #expect(h.view.tableCellEditor?.string == "old")
    }

    @Test func searchMapsEscapesInlineMarkupAndUnicodeToTheCorrectSource() throws {
        let source = "Intro\n\n|A|B|\n|-|-|\n|**😀 a** \\| [é](https://hidden.invalid)|`same` same|\n\nTail"
        let h = try Harness(source)
        defer { h.close() }
        let results = h.view.tableSearchResults(for: "😀 a | é")
        #expect(results.matches.count == 1)
        let match = try #require(results.matches.first)
        #expect((source as NSString).substring(with: match) == "😀 a** \\| [é")
        #expect(h.view.tableSearchResults(for: "hidden.invalid").matches.isEmpty)
        let same = h.view.tableSearchResults(for: "same").matches
        #expect(same.count == 2)
        #expect(same[0].location != same[1].location)
        h.view.setTableFindHighlights(results.matches, current: match)
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let cell = try #require(table.layout.cellText(row: 1, column: 0))
        let marked = h.view.highlightedTableCell(cell, tableRange: table.range, row: 1, column: 0)
        #expect(marked.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(h.view.string == source)
    }

    @Test func lineBreakAndCombiningCharacterOffsetsFollowRenderedText() throws {
        let source = "Intro\n\n|A|B|\n|-|-|\n|**é**<br/>😀|é|\n\nTail"
        let h = try Harness(source)
        defer { h.close() }
        let hits = h.view.tableSearchResults(for: "é\n😀").matches
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect((source as NSString).substring(with: hit) == "é**<br/>😀")
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let a = try #require(TableCellSource.cell(in: (source as NSString).substring(with: table.range), row: 1, column: 0))
        let projection = TableCellProjection(source: a, formatted: try #require(table.layout.cellText(row: 1, column: 0)))
        #expect(projection.text == "é\n😀")
        #expect(projection.sourceUnits.count == (projection.text as NSString).length)
        #expect(h.view.string == source)
    }

    @Test func searchRevealsAndDragCopiesBeyondTheReadingColumn() throws {
        let head = (0..<20).map { "H\($0)" }.joined(separator: "|")
        let row = (0..<20).map { "value\($0)" }.joined(separator: "|")
        let source = "Intro\n\n|\(head)|\n|\(String(repeating: "---|", count: 20))\n|\(row)|\n\nTail"
        let h = try Harness(source)
        defer { h.close() }
        let hit = try #require(h.view.tableSearchResults(for: "value19").matches.first)
        #expect(h.view.revealTableText(in: hit))
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        #expect(table.offset > 0)
        let start = try point(table, row: 1, column: 19)
        let end = try point(table, row: 1, column: 19, end: true)
        #expect(start.x > h.view.textContainerOrigin.x + 400)
        h.view.mouseDown(with: try event(.leftMouseDown, point: start, h: h))
        h.view.mouseDragged(with: try event(.leftMouseDragged, point: end, h: h))
        h.view.mouseUp(with: try event(.leftMouseUp, point: end, h: h))
        #expect(h.view.validTableSelection()?.text == "value19")
        #expect(h.view.renderedTable(at: h.tableStart)?.offset == table.offset)
        #expect(h.view.string == source)
    }
}
