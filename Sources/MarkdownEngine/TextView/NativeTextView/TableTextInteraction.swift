import AppKit

/// Host integration for rendered table text; all ranges index the editor's existing string.
@MainActor public protocol MarkdownTableTextAccess: AnyObject {
    func copySelectedTableText(to pasteboard: NSPasteboard) -> Bool
    func tableSearchResults(for query: String) -> (tables: [NSRange], matches: [NSRange])
    func setTableFindHighlights(_ ranges: [NSRange], current: NSRange?)
    func revealTableText(in range: NSRange) -> Bool
}

struct TableTextSelection {
    let tableRange: NSRange
    let snapshot: String
    let sourceRange: NSRange
    let text: String
}

struct TablePointer {
    let tableRange: NSRange
    let point: CGPoint
    let anchor: Int
    let content: TableTextContent
    let snapshot: String
    var dragging = false
}

struct TableTextContent {
    struct Cell {
        let row: Int
        let column: Int
        let start: Int
        let projection: TableCellProjection
    }
    let text: String
    let cells: [Cell]

    init(table: RenderedTable, source: String) {
        var text = ""
        var cells: [Cell] = []
        for row in 0..<table.layout.rowCount {
            for column in 0..<table.layout.columnCount {
                if column > 0 { text += "\t" } else if row > 0 { text += "\n" }
                guard let span = TableCellSource.cell(in: source, row: row, column: column),
                      let formatted = table.layout.cellText(row: row, column: column) else { continue }
                let projection = TableCellProjection(source: span, formatted: formatted)
                cells.append(Cell(row: row, column: column, start: (text as NSString).length, projection: projection))
                text += projection.text
            }
        }
        self.text = text; self.cells = cells
    }

    func sourceRange(for selected: NSRange) -> NSRange? {
        let spans = cells.compactMap { cell -> NSRange? in
            let overlap = NSIntersectionRange(selected, NSRange(location: cell.start, length: (cell.projection.text as NSString).length))
            guard overlap.length > 0 else { return nil }
            return cell.projection.sourceRange(for: NSRange(location: overlap.location - cell.start, length: overlap.length))
        }
        guard let first = spans.first, let last = spans.last else { return nil }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}

extension NativeTextView: MarkdownTableTextAccess {
    func validTableSelection() -> TableTextSelection? {
        guard !configuration.rawSourceMode, configuration.editsTableCells,
              let selected = tableTextSelection, selected.sourceRange == selectedRange(),
              NSMaxRange(selected.tableRange) <= (string as NSString).length,
              (string as NSString).substring(with: selected.tableRange) == selected.snapshot else { return nil }
        return selected
    }

    public func copySelectedTableText(to pasteboard: NSPasteboard) -> Bool {
        guard let selected = validTableSelection() else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(selected.text, forType: .string)
    }

    func beginTableTextPointer(with event: NSEvent) -> Bool {
        guard configuration.editsTableCells, !configuration.rawSourceMode,
              event.clickCount == 1, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = tableCell(at: point), let table = renderedTable(at: cell.tableRange.location) else { return false }
        let source = (string as NSString).substring(with: table.range)
        let content = TableTextContent(table: table, source: source)
        guard let index = tableTextIndex(at: point, table: table, content: content) else { return false }
        cancelTableTextPointer()
        endTableCellEditing()
        tableTextSelection = nil
        tablePointer = TablePointer(tableRange: table.range, point: point, anchor: index, content: content, snapshot: source)
        window?.makeFirstResponder(self)
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var pointer = tablePointer else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard pointer.dragging || hypot(point.x - pointer.point.x, point.y - pointer.point.y) >= 3 else { return }
        pointer.dragging = true; tablePointer = pointer
        tableDragWindowPoint = event.locationInWindow
        if tableDragTimer == nil {
            let timer = Timer(timeInterval: 1.0 / configuration.dragSelection.ticksPerSecond, repeats: true) { [weak self] _ in
                self?.performTableDragTick()
            }
            tableDragTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        updateTableDragSelection(at: point)
    }

    private func updateTableDragSelection(at point: CGPoint) {
        guard let pointer = tablePointer,
              let table = renderedTable(at: pointer.tableRange.location),
              NSMaxRange(table.range) <= (string as NSString).length,
              (string as NSString).substring(with: table.range) == pointer.snapshot else { cancelTableTextPointer(); return }
        let content = pointer.content
        guard let focus = tableTextIndex(at: point, table: table, content: content) else { return }
        let source = pointer.snapshot
        var selection = NSRange(location: min(pointer.anchor, focus), length: abs(focus - pointer.anchor))
        if selection.length > 0 { selection = (content.text as NSString).rangeOfComposedCharacterSequences(for: selection) }
        guard let local = content.sourceRange(for: selection) else {
            tableTextSelection = nil
            setSelectedRange(NSRange(location: table.range.location, length: 0))
            invalidateFragmentSurface(in: table.viewport)
            return
        }
        let range = NSRange(location: table.range.location + local.location, length: local.length)
        setSelectedRange(range)
        tableTextSelection = TableTextSelection(tableRange: table.range, snapshot: source, sourceRange: range,
                                                text: (content.text as NSString).substring(with: selection))
        invalidateFragmentSurface(in: table.viewport)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pointer = tablePointer else { super.mouseUp(with: event); return }
        cancelTableTextPointer()
        if !pointer.dragging { _ = beginTableCellEditing(at: pointer.point) }
    }

    func cancelTableTextPointer() {
        tableDragTimer?.invalidate(); tableDragTimer = nil
        tablePointer = nil; tableDragWindowPoint = nil
    }

    func performTableDragTick() {
        guard window != nil, !configuration.rawSourceMode,
              let pointer = tablePointer, pointer.dragging, let held = tableDragWindowPoint,
              let scroll = enclosingScrollView, let table = renderedTable(at: pointer.tableRange.location) else {
            cancelTableTextPointer(); return
        }
        let point = convert(held, from: nil)
        let edge = configuration.dragSelection.edgeTriggerDistance
        let visible = visibleRect
        let vertical: CGFloat = point.y < visible.minY + edge ? -1 : point.y > visible.maxY - edge ? 1 : 0
        var moved = false
        if vertical != 0 {
            let clip = scroll.contentView
            let old = clip.bounds.origin
            let desired = old.y + vertical * configuration.dragSelection.scrollStepPerTick
            let constrained = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: old.x, y: desired), size: clip.bounds.size))
            if constrained.origin != old {
                (scroll as? ClampedScrollView)?.cancelPendingScrollRestore()
                clip.scroll(to: constrained.origin)
                scroll.reflectScrolledClipView(clip)
                (scroll as? ClampedScrollView)?.clampToInsets()
                moved = true
            }
        }
        if let id = table.sourceID {
            let step: CGFloat = point.x < table.viewport.minX + edge ? -24 : point.x > table.viewport.maxX - edge ? 24 : 0
            let offset = min(max(0, table.offset + step), max(0, table.layout.size.width - table.viewport.width))
            if offset != table.offset { tableHorizontalScrollOffsets[id] = offset; moved = true }
        }
        if moved { updateTableDragSelection(at: convert(held, from: nil)) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelTableTextPointer() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if validTableSelection() != nil {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            return menu
        }
        return super.menu(for: event)
    }

    private func tableTextIndex(at point: CGPoint, table: RenderedTable, content: TableTextContent) -> Int? {
        let local = CGPoint(x: min(max(0, point.x - table.viewport.minX + table.offset), table.layout.size.width - 1),
                            y: min(max(0, point.y - table.viewport.minY), table.layout.size.height - 1))
        guard let target = table.layout.cell(at: local),
              let formatted = table.layout.cellText(row: target.row, column: target.column),
              let rect = table.layout.cellTextRect(row: target.row, column: target.column) else { return nil }
        guard let cell = content.cells.first(where: { $0.row == target.row && $0.column == target.column }) else { return nil }
        let geometry = TableCellTextGeometry(formatted, size: rect.size, alignment: table.layout.alignments[target.column])
        return cell.start + geometry.insertionIndex(at: CGPoint(x: local.x - rect.minX, y: local.y - rect.minY))
    }

    public func tableSearchResults(for query: String) -> (tables: [NSRange], matches: [NSRange]) {
        guard !configuration.rawSourceMode, let coordinator = delegate as? NativeTextViewCoordinator,
              let parsed = coordinator.cachedParsedDocument else { return ([], []) }
        var tables: [NSRange] = [], matches: [NSRange] = []
        for (_, token) in parsed.classified.table {
            ensureLayout(forCharacterRange: token.range)
            guard let table = renderedTable(at: token.range.location) else { continue }
            tables.append(table.range)
            let content = TableTextContent(table: table, source: (string as NSString).substring(with: table.range))
            guard !query.isEmpty else { continue }
            for cell in content.cells {
                let text = cell.projection.text as NSString
                var start = 0
                while start < text.length {
                    let hit = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: text.length - start))
                    guard hit.location != NSNotFound else { break }
                    if let source = cell.projection.sourceRange(for: hit) {
                        matches.append(NSRange(location: table.range.location + source.location, length: source.length))
                    }
                    start = NSMaxRange(hit)
                }
            }
        }
        return (tables, matches)
    }

    public func setTableFindHighlights(_ ranges: [NSRange], current: NSRange?) {
        tableFindRanges = ranges; tableFindCurrent = current
        invalidateFragmentSurface(in: visibleRect)
    }

    public func revealTableText(in range: NSRange) -> Bool {
        guard !configuration.rawSourceMode, range.location != NSNotFound, range.length > 0,
              let coordinator = delegate as? NativeTextViewCoordinator,
              let parsed = coordinator.cachedParsedDocument else { return false }
        let nearby = MarkdownStyler.scopedSlice(parsed.classified.table, lo: range.location, hi: NSMaxRange(range) + 1)
        guard let token = nearby.first(where: { NSIntersectionRange($0.1.range, range).length > 0 })?.1 else { return false }
        endTableCellEditing()
        ensureLayout(forCharacterRange: token.range)
        guard let table = renderedTable(at: token.range.location) else { return false }
        let content = TableTextContent(table: table, source: (string as NSString).substring(with: table.range))
        let overlap = NSIntersectionRange(range, table.range)
        let local = NSRange(location: overlap.location - table.range.location, length: overlap.length)
        guard let target = content.cells.first(where: { !$0.projection.displayRanges(for: local).isEmpty }),
              let cellRect = table.layout.cellTextRect(row: target.row, column: target.column),
              let formatted = table.layout.cellText(row: target.row, column: target.column),
              let displayRange = target.projection.displayRanges(for: local).first else { return false }
        let geometry = TableCellTextGeometry(formatted, size: cellRect.size, alignment: table.layout.alignments[target.column])
        let rect = geometry.rect(for: displayRange).offsetBy(dx: cellRect.minX, dy: cellRect.minY)
        if let id = table.sourceID {
            var offset = table.offset
            if rect.minX < offset { offset = rect.minX }
            if rect.maxX > offset + table.viewport.width { offset = rect.maxX - table.viewport.width }
            tableHorizontalScrollOffsets[id] = max(0, min(offset, table.layout.size.width - table.viewport.width))
        }
        scrollToVisible(CGRect(x: table.viewport.minX, y: table.viewport.minY + rect.minY, width: table.viewport.width, height: rect.height))
        invalidateFragmentSurface(in: table.viewport)
        return true
    }

    func highlightedTableCell(_ cell: NSAttributedString, tableRange: NSRange, row: Int, column: Int) -> NSAttributedString {
        let hasSelection = tableCellEditor == nil && NSIntersectionRange(selectedRange(), tableRange).length > 0
        guard hasSelection || tableFindRanges.contains(where: { NSIntersectionRange($0, tableRange).length > 0 }) else { return cell }
        guard NSMaxRange(tableRange) <= (string as NSString).length,
              let source = TableCellSource.cell(in: (string as NSString).substring(with: tableRange), row: row, column: column) else { return cell }
        let projection = TableCellProjection(source: source, formatted: cell)
        let output = NSMutableAttributedString(attributedString: cell)
        func highlight(_ range: NSRange, color: NSColor) {
            guard NSIntersectionRange(range, tableRange).length > 0 else { return }
            let local = NSRange(location: max(0, range.location - tableRange.location), length: NSMaxRange(range) - max(range.location, tableRange.location))
            for mapped in projection.displayRanges(for: local) { output.addAttribute(.backgroundColor, value: color, range: mapped) }
        }
        for range in tableFindRanges { highlight(range, color: configuration.theme.findMatchHighlight.withAlphaComponent(0.35)) }
        if let current = tableFindCurrent { highlight(current, color: configuration.theme.findCurrentMatchHighlight) }
        if tableCellEditor == nil, selectedRange().length > 0 { highlight(selectedRange(), color: .selectedTextBackgroundColor) }
        return output
    }
}
