import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Native cell editing", .serialized)
@MainActor
struct TableCellEditorTests {
    @MainActor final class Harness {
        let stack = HeightBehaviorStack(viewport: NSSize(width: 1000, height: 700))
        let coordinator: NativeTextViewCoordinator
        let layoutDelegate = MarkdownLayoutManagerDelegate()
        let bridge: LayoutBridge
        let window: NSWindow
        let tableStart: Int
        var view: NativeTextView { stack.textView }

        init(_ source: String = "Intro.\n\n| A | B |\n|---|---|\n| old | other |\n\nTail.") throws {
            _ = NSApplication.shared
            tableStart = (source as NSString).range(of: "|").location
            coordinator = NativeTextViewCoordinator(text: .constant(source), fontName: "Helvetica", fontSize: 15,
                isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil)
            bridge = LayoutBridge(try #require(stack.textView.textLayoutManager))
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            view.configuration.tablesUseAvailableWidth = true
            view.configuration.editsTableCells = true
            view.configuration.textInsets = TextInsets(horizontal: 32, vertical: 0)
            view.textContainer?.lineFragmentPadding = 0
            view.applyReadingWidth(400)
            view.textLayoutManager?.delegate = layoutDelegate
            view.layoutBridge = bridge
            view.isEditable = true
            view.allowsUndo = true
            view.string = source
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            view.delegate = coordinator
            coordinator.textView = view
            coordinator.layoutBridge = bridge
            coordinator.configuration = view.configuration
            coordinator.lastSyncedText = source
            coordinator.lastComputedStorage = source
            coordinator.previousDisplayLength = (source as NSString).length
            coordinator.restyleParagraphs([NSRange(location: 0, length: (source as NSString).length)], in: view)
            view.textLayoutManager?.ensureLayout(for: try #require(view.textLayoutManager).documentRange)
            window.contentView = stack.scrollView
            window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
            window.orderBack(nil)
            view.undoManager?.removeAllActions()
        }

        func begin(row: Int = 1, column: Int = 0) throws -> TableCellEditor {
            let table = try #require(view.renderedTable(at: tableStart))
            let cell = try #require(table.cell(row: row, column: column))
            #expect(view.beginTableCellEditing(at: CGPoint(x: cell.rect.midX, y: cell.rect.midY)))
            return try #require(view.tableCellEditor)
        }

        func close() { view.endTableCellEditing(); window.orderOut(nil) }
    }

    @Test func typingPublishesOnlyTheCellAndKeepsTableRendered() throws {
        let h = try Harness()
        defer { h.close() }
        let field = try h.begin()
        field.insertText("😀 | `code | pipe`", replacementRange: field.selectedRange())
        #expect(h.view.string.contains("| 😀 \\| `code \\| pipe` | other |"))
        #expect(h.coordinator.lastComputedStorage == h.view.string)
        #expect(h.view.renderedTable(at: h.tableStart) != nil)
        #expect(h.view.tableCellEditor === field)
        #expect(h.window.firstResponder === field)
    }

    @Test func whitespaceDoesNotAccumulateBetweenKeystrokes() throws {
        let h = try Harness()
        defer { h.close() }
        let field = try h.begin()
        field.insertText(" x ", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        field.insertText(" xy ", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        #expect(h.view.string.contains("|  xy  | other |"))
    }

    @Test func escapeRestoresTheExactInitialTable() throws {
        let h = try Harness()
        defer { h.close() }
        let original = h.view.string
        let field = try h.begin()
        field.insertText("changed", replacementRange: field.selectedRange())
        #expect(field.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(h.view.string == original)
        #expect(h.view.tableCellEditor == nil)
    }

    @Test func documentUndoRedoRetainsSourceAndFieldUndoUsesTheSameManager() throws {
        let h = try Harness()
        defer { h.close() }
        let original = h.view.string
        let manager = try #require(h.view.undoManager)
        manager.groupsByEvent = false
        let field = try h.begin()
        manager.beginUndoGrouping()
        field.insertText("new", replacementRange: field.selectedRange())
        manager.endUndoGrouping()
        let edited = h.view.string
        #expect(edited != original)
        #expect(manager.canUndo)
        field.undo(nil)
        #expect(h.view.string == original)
        #expect(manager.canRedo)
        manager.redo()
        #expect(h.view.string == edited)
    }

    @Test func markedCellInputIsVisibleToTheDocumentSaveGate() throws {
        let h = try Harness()
        defer { h.close() }
        let field = try h.begin()
        let before = h.view.string
        field.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: field.selectedRange())
        #expect(field.hasMarkedText())
        #expect(h.view.hasMarkedText())
        #expect(h.view.string == before)
        field.unmarkText()
        #expect(!h.view.hasMarkedText())
        #expect(h.view.string.contains("| あ | other |"))
    }

    @Test func editingATableAtTheEndOfTheDocumentKeepsItRendered() throws {
        let h = try Harness("| A | B |\n|---|---|\n| old | other |")
        defer { h.close() }
        let field = try h.begin()
        field.insertText("last", replacementRange: field.selectedRange())
        #expect(h.view.tableCellEditor === field)
        #expect(h.view.renderedTable(at: h.tableStart) != nil)
        #expect(field.textView(field, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(h.view.renderedTable(at: h.tableStart) != nil)
    }

    private func key(_ characters: String, code: UInt16, in h: Harness) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        let responder = try #require(h.window.firstResponder as? NSTextView)
        responder.keyDown(with: event)
    }

    @Test func returnAfterCellEditingCreatesAParagraphAfterAnEOFTable() throws {
        let h = try Harness("| A | B |\n|---|---|\n| old | other |")
        defer { h.close() }
        let field = try h.begin()
        field.insertText("last", replacementRange: field.selectedRange())
        try key("\r", code: 36, in: h)
        #expect(h.view.tableCellEditor == nil)
        let tableSource = h.view.string
        try key("\r", code: 36, in: h)
        try key("\r", code: 36, in: h)
        try key("x", code: 7, in: h)
        #expect(h.view.tableCellEditor == nil)
        #expect(h.view.string == tableSource + "\n\nx")
    }

    @Test func arrowKeysAtTableBoundaryDoNotOpenACell() throws {
        let h = try Harness("| A | B |\n|---|---|\n| old | other |")
        defer { h.close() }
        h.window.makeFirstResponder(h.view)
        let source = h.view.string
        try key("\u{f702}", code: 123, in: h)
        #expect(h.view.tableCellEditor == nil)
        try key("\u{f703}", code: 124, in: h)
        #expect(h.view.tableCellEditor == nil)
        #expect(h.view.string == source)
    }

    @Test func ordinaryTypingAfterATableStaysInTheDocument() throws {
        let h = try Harness()
        defer { h.close() }
        h.window.makeFirstResponder(h.view)
        let source = h.view.string
        try key("x", code: 7, in: h)
        #expect(h.view.tableCellEditor == nil)
        #expect(h.view.string == source + "x")
    }

    @Test(arguments: [0, 1]) func deletingACompactSingleCellKeepsEditingAndEscape(row: Int) throws {
        let original = "|A|\n|-|\n|x|"
        let h = try Harness(original)
        defer { h.close() }
        let field = try h.begin(row: row)
        field.selectAll(nil)
        try key("\u{7f}", code: 51, in: h)
        #expect(h.view.tableCellEditor === field)
        #expect(field.string.isEmpty)
        #expect(h.view.renderedTable(at: h.tableStart)?.cell(row: row, column: 0) != nil)
        try key("z", code: 6, in: h)
        #expect(field.string == "z")
        #expect(h.view.string == original.replacingOccurrences(of: row == 0 ? "|A|" : "|x|", with: "|z|"))
        try key("\u{1b}", code: 53, in: h)
        #expect(h.view.tableCellEditor == nil)
        #expect(h.view.string == original)
    }

    @Test func openingAndClosingACellDoesNotNormalizeItsExistingSource() throws {
        let original = "Intro.\n\n| A | B |\n|---|---|\n|  `a \\| b`  |   |\n\nTail."
        let h = try Harness(original)
        defer { h.close() }
        let field = try h.begin()
        field.unmarkText()
        h.view.endTableCellEditing()
        #expect(h.view.string == original)
        #expect(h.view.undoManager?.canUndo == false)
    }

    @Test func keyboardEntryTargetsTheCellAtTheCaret() throws {
        let h = try Harness()
        defer { h.close() }
        let range = (h.view.string as NSString).range(of: "other")
        h.view.setSelectedRange(NSRange(location: range.location + 2, length: 0))
        #expect(h.view.beginTableCellEditingForSelection())
        let field = try #require(h.view.tableCellEditor)
        #expect(field.string == "other")
        #expect(field.selectedRange() == NSRange(location: 2, length: 0))
        field.insertText("X", replacementRange: field.selectedRange())
        #expect(h.view.string.contains("otXher"))
    }

    @Test func aTrailingBackslashCannotConsumeTheCellDelimiter() throws {
        let h = try Harness("Intro.\n\n|A|B|\n|-|-|\n|old|other|")
        defer { h.close() }
        let field = try h.begin()
        field.insertText("x\\", replacementRange: field.selectedRange())
        #expect(h.view.string.hasSuffix("|x\\\\|other|"))
        #expect(h.view.renderedTable(at: h.tableStart)?.layout.columnCount == 2)
    }

    @Test func escapeRestoresAnOmittedCellWithoutLeavingNewSeparators() throws {
        let initial = "Intro.\n\n|A|B|\n|-|-|\n|old|"
        let h = try Harness(initial)
        defer { h.close() }
        let field = try h.begin(row: 1, column: 1)
        field.insertText("filled", replacementRange: field.selectedRange())
        #expect(h.view.string.hasSuffix("|old| filled |"))
        #expect(field.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(h.view.string == initial)
    }

    @Test func focusChangeKeepsAlreadyPublishedText() throws {
        let h = try Harness()
        defer { h.close() }
        let field = try h.begin()
        field.insertText("saved", replacementRange: field.selectedRange())
        h.window.makeFirstResponder(h.view)
        #expect(h.view.tableCellEditor == nil)
        #expect(h.view.string.contains("| saved | other |"))
    }

    @Test func editingOutsideReadingColumnAfterHorizontalScrollPreservesOffset() throws {
        let header = (0..<24).map { "column\($0)" }.joined(separator: " | ")
        let body = (0..<24).map { "value\($0)" }.joined(separator: " | ")
        let h = try Harness("Intro.\n\n| \(header) |\n|\(String(repeating: "---|", count: 24))\n| \(body) |\n\nTail.")
        defer { h.close() }
        let table = try #require(h.view.renderedTable(at: h.tableStart))
        let id = try #require(table.sourceID)
        let offset = table.layout.columnLeft[12]
        h.view.tableHorizontalScrollOffsets[id] = offset
        let moved = try #require(h.view.renderedTable(at: h.tableStart))
        let cell = try #require(moved.cell(row: 1, column: 12))
        #expect(cell.rect.midX < h.view.textContainerOrigin.x)
        let field = try h.begin(row: 1, column: 12)
        #expect(field.string == "value12")
        field.insertText("edited12", replacementRange: field.selectedRange())
        let after = try #require(h.view.renderedTable(at: h.tableStart))
        let newID = try #require(after.sourceID)
        #expect(h.view.tableHorizontalScrollOffsets[newID] == offset)
        #expect(h.view.string.contains("value11 | edited12 | value13"))
    }
}
