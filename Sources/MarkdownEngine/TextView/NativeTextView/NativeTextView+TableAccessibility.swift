//
//  NativeTextView+TableAccessibility.swift
//  MarkdownEngine
//
//  A table drawn as text is invisible to VoiceOver: the text view's value is
//  the raw source, and the grid is only pixels. This exposes every table whose
//  fragment lies in the visible part of the document as an accessibility table
//  with rows, cells and one text element per cell, framed where the fragment
//  draws them, so VoiceOver can walk the grid and read each cell.
//
//  Ownership: the accessibility server refers to elements by identity, so the
//  text view keeps one tree per table (`tableAccessibilityTables`) for as long
//  as the table is visible and reuses it across queries. The elements store
//  nothing that moves: frames, values and the set of visible cells are read
//  from the rendered table on every query, so scrolling the document or a
//  wide table never leaves a stale rectangle behind. A tree is replaced when
//  its table changes shape, and dropped when the table leaves the viewport.
//

import AppKit

/// One node of a table's accessibility tree. Everything geometric is derived
/// on demand from the text view's rendered table; the element only knows
/// where it sits in the grid.
final class TableAccessibilityElement: NSAccessibilityElement {

    enum Kind {
        case table
        case row(Int)
        case cell(row: Int, column: Int)
        case text(row: Int, column: Int)
    }

    weak var textView: NativeTextView?
    let tableLocation: Int
    let kind: Kind
    /// Children are held strongly for the element's whole life; the row's
    /// answer filters them to the cells currently inside the table's box.
    private(set) var rows: [TableAccessibilityElement] = []
    private(set) var cells: [TableAccessibilityElement] = []
    private(set) var text: TableAccessibilityElement?

    init(textView: NativeTextView, tableLocation: Int, kind: Kind, parent: Any) {
        self.textView = textView
        self.tableLocation = tableLocation
        self.kind = kind
        super.init()
        setAccessibilityElement(true)
        setAccessibilityParent(parent)
        switch kind {
        case .table: setAccessibilityRole(.table)
        case .row(let index):
            setAccessibilityRole(.row)
            setAccessibilityIndex(index)
        case .cell(let row, let column):
            setAccessibilityRole(.cell)
            setAccessibilityRowIndexRange(NSRange(location: row, length: 1))
            setAccessibilityColumnIndexRange(NSRange(location: column, length: 1))
        case .text: setAccessibilityRole(.staticText)
        }
    }

    /// Builds the rows, cells and text elements for a table of this shape.
    func populate(rowCount: Int, columnCount: Int) {
        guard let textView, case .table = kind else { return }
        rows = (0..<rowCount).map { row in
            let rowElement = TableAccessibilityElement(textView: textView, tableLocation: tableLocation, kind: .row(row), parent: self)
            rowElement.cells = (0..<columnCount).map { column in
                let cell = TableAccessibilityElement(
                    textView: textView, tableLocation: tableLocation, kind: .cell(row: row, column: column), parent: rowElement
                )
                cell.text = TableAccessibilityElement(
                    textView: textView, tableLocation: tableLocation, kind: .text(row: row, column: column), parent: cell
                )
                return cell
            }
            return rowElement
        }
        setAccessibilityRows(rows)
        setAccessibilityRowCount(rowCount)
        setAccessibilityColumnCount(columnCount)
        // The header row's cells head their columns; VoiceOver announces the
        // header when the cursor enters a column.
        if let header = rows.first {
            setAccessibilityColumnHeaderUIElements(header.cells)
            for row in rows.dropFirst() {
                for (column, cell) in row.cells.enumerated() {
                    cell.setAccessibilityColumnHeaderUIElements([header.cells[column]])
                }
            }
        }
    }

    private var table: RenderedTable? { textView?.renderedTable(at: tableLocation) }

    /// The cells of a row that lie inside the table's box, minus the one a
    /// cell editor currently covers with a live text view of its own.
    func visibleCells() -> [TableAccessibilityElement] {
        guard let table, let textView else { return [] }
        return cells.filter { cell in
            guard case .cell(let row, let column) = cell.kind,
                  table.cell(row: row, column: column) != nil else { return false }
            if let editing = textView.tableCellEditor?.cell,
               editing.tableRange.location == tableLocation, editing.row == row, editing.column == column {
                return false
            }
            return true
        }
    }

    private func currentChildren() -> [TableAccessibilityElement] {
        switch kind {
        case .table: return rows
        case .row: return visibleCells()
        case .cell: return text.map { [$0] } ?? []
        case .text: return []
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let children = currentChildren()
        return children.isEmpty ? nil : children
    }

    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        let children = currentChildren()
        return children.isEmpty ? nil : children
    }

    /// The protocol wants a non-optional identifier; the element's is optional.
    override func accessibilityIdentifier() -> String {
        super.accessibilityIdentifier() ?? ""
    }

    override func accessibilityFrame() -> NSRect {
        guard let textView, let table else { return .zero }
        let rect: CGRect?
        switch kind {
        case .table:
            rect = table.viewport
        case .row:
            let rects = visibleCells().compactMap { cell -> CGRect? in
                guard case .cell(let row, let column) = cell.kind else { return nil }
                return table.cell(row: row, column: column)?.rect
            }
            rect = rects.dropFirst().reduce(rects.first) { $0?.union($1) }
        case .cell(let row, let column), .text(let row, let column):
            rect = table.cell(row: row, column: column)?.rect
        }
        guard let rect else { return .zero }
        return textView.screenRect(rect)
    }

    override func accessibilityValue() -> Any? {
        switch kind {
        case .cell(let row, let column), .text(let row, let column):
            return table?.layout.cellText(row: row, column: column)?.string
        case .table, .row:
            return nil
        }
    }
}

/// `NSAccessibilityElement` implements the element protocol's methods but does
/// not adopt the protocol itself. AppKit derives a view's navigation order from
/// its children and Swift bridges that array as elements of this protocol, so
/// a child that does not adopt it crashes the bridge.
extension TableAccessibilityElement: NSAccessibilityElementProtocol {}

extension NativeTextView {

    // MARK: - Overrides

    override func accessibilityChildren() -> [Any]? {
        let base = super.accessibilityChildren() ?? []
        let tables = tableAccessibilityElements()
        if tables.isEmpty { return base.isEmpty ? nil : base }
        return base + tables
    }

    /// Screen point to the cell text under it, so VoiceOver's pointer tracking
    /// lands on cells instead of on the text area as a whole. A subview that
    /// claims the point first — the cell editor — wins.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let base = super.accessibilityHitTest(point)
        if let view = base as? NSView, view !== self { return base }
        for table in tableAccessibilityElements() {
            for row in table.rows {
                for cell in row.visibleCells() where cell.accessibilityFrame().contains(point) {
                    return cell.text ?? cell
                }
            }
        }
        return base
    }

    // MARK: - Visible tables

    /// One `.table` element per rendered table in the visible part of the
    /// document, in document order, reused from `tableAccessibilityTables`
    /// while the table keeps its location and shape.
    func tableAccessibilityElements() -> [TableAccessibilityElement] {
        guard !configuration.rawSourceMode, window != nil else { return [] }
        var current: [Int: TableAccessibilityElement] = [:]
        let elements = visibleRenderedTables().map { table -> TableAccessibilityElement in
            let location = table.range.location
            let shape = (table.layout.rowCount, table.layout.columnCount)
            let element: TableAccessibilityElement
            if let cached = tableAccessibilityTables[location],
               cached.accessibilityRowCount() == shape.0, cached.accessibilityColumnCount() == shape.1 {
                element = cached
            } else {
                element = TableAccessibilityElement(textView: self, tableLocation: location, kind: .table, parent: self)
                element.populate(rowCount: shape.0, columnCount: shape.1)
            }
            current[location] = element
            return element
        }
        tableAccessibilityTables = current
        return elements
    }

    /// The tables of every fragment that intersects the visible rect, in the
    /// same geometry the fragment draws and hit-tests them with. Fragments are
    /// walked from the one under the viewport's top edge and only as far as
    /// its bottom edge, so a staged open never has to lay out the rest.
    func visibleRenderedTables() -> [RenderedTable] {
        guard let tlm = textLayoutManager else { return [] }
        let visible = visibleRect
        let top = CGPoint(x: 0, y: max(0, visible.minY - textContainerOrigin.y))
        guard let first = tlm.textLayoutFragment(for: top) else { return [] }
        var tables: [RenderedTable] = []
        tlm.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let origin = CGPoint(x: frame.minX + textContainerOrigin.x, y: frame.minY + textContainerOrigin.y)
            if origin.y > visible.maxY { return false }
            // Below the document's end the clamp lands on the last fragment,
            // which may lie entirely above the viewport.
            if origin.y + frame.height < visible.minY { return true }
            // A fragment straddling the viewport's edge can hold a table whose
            // box lies entirely outside it (paragraph spacing is part of the
            // fragment); only tables whose box is in view are reported.
            if let markdown = fragment as? MarkdownTextLayoutFragment {
                tables += markdown.renderedTables(at: origin).filter { $0.viewport.intersects(visible) }
            }
            return true
        }
        return tables
    }

    /// View rect to screen rect, as accessibility frames are reported.
    func screenRect(_ rect: NSRect) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
}
