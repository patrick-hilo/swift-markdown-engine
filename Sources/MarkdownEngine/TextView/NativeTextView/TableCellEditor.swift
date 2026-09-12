import AppKit

/// One transient editor; the document's text view remains the source and undo owner.
final class TableCellEditor: NSTextView, NSTextViewDelegate {
    weak var owner: NativeTextView?
    var cell: RenderedTableCell
    let initialTable: String
    var lastTable: String
    var lastInput: String
    let source: TableCellSource
    var replacementRange: NSRange
    var publishing = false
    private var changeObserver: NSObjectProtocol?

    init(owner: NativeTextView, cell: RenderedTableCell, table: String, source: TableCellSource) {
        self.owner = owner
        self.cell = cell
        initialTable = table
        lastTable = table
        lastInput = source.text
        self.source = source
        replacementRange = NSRange(location: cell.tableRange.location + source.range.location, length: source.range.length)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: cell.rect.width, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: .zero, size: cell.rect.size), textContainer: container)
        isRichText = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        font = owner.baseFont
        textColor = owner.configuration.theme.bodyText
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 6, height: 6)
        string = source.text
        delegate = self
        setAccessibilityLabel("Table cell, row \(cell.row + 1), column \(cell.column + 1)")
        toolTip = "Edit cell Markdown. Changes update the document immediately. Return finishes; Escape restores the original cell."
        changeObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: owner, queue: .main) { [weak self] _ in
            guard let self, !self.publishing else { return }
            self.owner?.endTableCellEditing()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    func textDidChange(_ notification: Notification) {
        guard !publishing, !hasMarkedText(), let owner else { return }
        if !owner.publishTableCell(self, text: string) { owner.endTableCellEditing() }
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        super.unmarkText()
        if !publishing, let owner {
            _ = owner.publishTableCell(self, text: string)
            if wasMarked {
                publishing = true
                NotificationCenter.default.post(name: NSText.didChangeNotification, object: owner)
                publishing = false
            }
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) || commandSelector == #selector(insertTab(_:)) || commandSelector == #selector(insertBacktab(_:)) {
            owner?.endTableCellEditing()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            if let owner { _ = owner.restoreTableCell(self); owner.endTableCellEditing() }
            return true
        }
        return false
    }

    @objc func undo(_ sender: Any?) {
        guard let owner else { return }
        owner.endTableCellEditing()
        owner.undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let owner else { return }
        owner.endTableCellEditing()
        owner.undoManager?.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return owner?.undoManager?.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return owner?.undoManager?.canRedo ?? false }
        return super.validateUserInterfaceItem(item)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { owner?.endTableCellEditing(restoreFocus: false) }
        return resigned
    }
}

extension NativeTextView {
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command), beginTableCellEditingForSelection(), let field = tableCellEditor {
            field.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    /// Keyboard input at the document caret enters that cell instead of editing hidden delimiters.
    func beginTableCellEditingForSelection() -> Bool {
        let selection = selectedRange()
        guard configuration.editsTableCells, !configuration.rawSourceMode, selection.length == 0,
              selection.location != NSNotFound,
              let coordinator = delegate as? NativeTextViewCoordinator,
              let parsed = coordinator.cachedParsedDocument else { return false }
        let nearby = MarkdownStyler.scopedSlice(parsed.classified.table, lo: max(0, selection.location - 1), hi: selection.location + 1)
        guard let token = nearby.first(where: {
            selection.location >= $0.1.range.location && selection.location <= NSMaxRange($0.1.range)
        })?.1, let table = renderedTable(at: token.range.location) else { return false }
        let text = (string as NSString).substring(with: table.range)
        var closest: (row: Int, column: Int, source: TableCellSource, distance: Int)?
        let local = selection.location - table.range.location
        let ns = text as NSString
        var lineStart = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: min(local, max(0, ns.length - 1)), length: 0))
        let line = ns.substring(to: lineStart).components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let row = max(0, line - 1)
        for column in 0..<table.layout.columnCount {
            guard let source = TableCellSource.cell(in: text, row: row, column: column) else { continue }
            let distance = max(source.range.location - local, local - NSMaxRange(source.range), 0)
            if distance < (closest?.distance ?? .max) { closest = (row, column, source, distance) }
        }
        guard let target = closest else { return false }
        if table.cell(row: target.row, column: target.column) == nil, let id = table.sourceID {
            tableHorizontalScrollOffsets[id] = min(max(0, table.layout.size.width - table.viewport.width), table.layout.columnLeft[target.column])
        }
        guard let cell = renderedTable(at: table.range.location)?.cell(row: target.row, column: target.column),
              beginTableCellEditing(at: CGPoint(x: cell.rect.midX, y: cell.rect.midY)), let field = tableCellEditor else { return false }
        field.setSelectedRange(NSRange(location: min(max(0, local - target.source.range.location), (field.string as NSString).length), length: 0))
        return true
    }

    func renderedTable(at offset: Int) -> RenderedTable? {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let location = content.location(manager.documentRange.location, offsetBy: offset),
              let fragment = manager.textLayoutFragment(for: location) as? MarkdownTextLayoutFragment else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        return fragment.renderedTables(at: CGPoint(x: origin.x + textContainerOrigin.x, y: origin.y + textContainerOrigin.y))
            .first { $0.range.location == offset }
    }

    func tableCell(at point: CGPoint) -> RenderedTableCell? {
        guard let manager = textLayoutManager else { return nil }
        let x = min(max(0, point.x - textContainerOrigin.x), max(0, (textContainer?.size.width ?? 1) - 1))
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: x, y: point.y - textContainerOrigin.y)) as? MarkdownTextLayoutFragment else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        return fragment.renderedTables(at: CGPoint(x: origin.x + textContainerOrigin.x, y: origin.y + textContainerOrigin.y))
            .compactMap { $0.cell(at: point) }.first
    }

    func beginTableCellEditing(at point: CGPoint) -> Bool {
        guard configuration.editsTableCells, isEditable, !configuration.rawSourceMode,
              let cell = tableCell(at: point), NSMaxRange(cell.tableRange) <= (string as NSString).length else { return false }
        endTableCellEditing(restoreFocus: false)
        let table = (string as NSString).substring(with: cell.tableRange)
        guard let source = TableCellSource.cell(in: table, row: cell.row, column: cell.column) else { return false }
        let field = TableCellEditor(owner: self, cell: cell, table: table, source: source)
        let scroll = NSScrollView(frame: cell.rect)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = field
        field.isVerticallyResizable = true
        field.autoresizingMask = [.width]
        tableCellEditor = field
        addSubview(scroll)
        positionTableCellEditor(field)
        window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length))
        return true
    }

    func endTableCellEditing(restoreFocus: Bool = true) {
        guard let field = tableCellEditor else { return }
        if field.hasMarkedText() { field.unmarkText() }
        tableCellEditor = nil
        field.owner = nil
        if restoreFocus, window?.firstResponder === field { window?.makeFirstResponder(self) }
        field.enclosingScrollView?.removeFromSuperview()
    }

    private func positionTableCellEditor(_ field: TableCellEditor) {
        guard let scroll = field.enclosingScrollView else { return }
        let available = field.cell.viewport
        let width = min(max(160, field.cell.rect.width), available.width)
        let x = max(available.minX, min(field.cell.rect.minX, available.maxX - width))
        scroll.frame = CGRect(x: x, y: field.cell.rect.minY, width: width, height: max(64, field.cell.rect.height))
        field.setFrameSize(CGSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, field.frame.height)))
    }

    @discardableResult
    func publishTableCell(_ field: TableCellEditor, text: String) -> Bool {
        guard tableCellEditor === field, NSMaxRange(field.cell.tableRange) <= (string as NSString).length else { return false }
        let current = (string as NSString).substring(with: field.cell.tableRange)
        guard current == field.lastTable else { return false }
        guard text != field.lastInput else { return true }
        let replacement = field.source.replacement(for: text)
        let range = field.replacementRange
        if (string as NSString).substring(with: range) != replacement {
            guard replaceTableCellSource(field, range: range, replacement: replacement) else { return false }
        }
        field.lastInput = text
        field.replacementRange.length = (replacement as NSString).length
        return true
    }

    @discardableResult
    func restoreTableCell(_ field: TableCellEditor) -> Bool {
        if field.hasMarkedText() { field.unmarkText() }
        guard tableCellEditor === field, NSMaxRange(field.cell.tableRange) <= (string as NSString).length,
              (string as NSString).substring(with: field.cell.tableRange) == field.lastTable else { return false }
        if field.lastTable == field.initialTable { return true }
        return replaceTableCellSource(field, range: field.cell.tableRange, replacement: field.initialTable)
    }

    private func registerTableOffsetUndo(restoring id: Int, opposite: Int, offset: CGFloat) {
        undoManager?.registerUndo(withTarget: self) { view in
            view.tableHorizontalScrollOffsets[id] = offset
            view.registerTableOffsetUndo(restoring: opposite, opposite: id, offset: offset)
        }
    }

    private func replaceTableCellSource(_ field: TableCellEditor, range: NSRange, replacement: String) -> Bool {
        guard let storage = textStorage, let coordinator = delegate as? NativeTextViewCoordinator else { return false }
        field.publishing = true
        let wasProgrammatic = coordinator.isProgrammaticEdit
        coordinator.isProgrammaticEdit = true
        defer { coordinator.isProgrammaticEdit = wasProgrammatic; field.publishing = false }
        let oldOffset = field.cell.sourceID.flatMap { tableHorizontalScrollOffsets[$0] } ?? 0
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        storage.replaceCharacters(in: range, with: replacement)
        let newLength = field.cell.tableRange.length + (replacement as NSString).length - range.length
        let newRange = NSRange(location: field.cell.tableRange.location, length: newLength)
        // Keep the document caret outside the table; only the cell field owns input here.
        setSelectedRange(NSRange(location: min(NSMaxRange(newRange), storage.length), length: 0))
        didChangeText()
        coordinator.restyleParagraphs([newRange], in: self)
        ensureLayout(forCharacterRange: newRange)
        guard var table = renderedTable(at: newRange.location) else { return false }
        if let id = table.sourceID {
            tableHorizontalScrollOffsets[id] = oldOffset
            if let refreshed = renderedTable(at: newRange.location) { table = refreshed }
        }
        guard let cell = table.cell(row: field.cell.row, column: field.cell.column) else { return false }
        if let oldID = field.cell.sourceID, let newID = cell.sourceID, oldID != newID {
            registerTableOffsetUndo(restoring: oldID, opposite: newID, offset: oldOffset)
        }
        undoManager?.setActionName("Edit Table Cell")
        field.cell = cell
        field.lastTable = (storage.string as NSString).substring(with: cell.tableRange)
        positionTableCellEditor(field)
        invalidateFragmentSurface(in: table.viewport)
        return true
    }
}

