//
//  LegacyTableRenderer.swift
//  MarkdownEngineTests
//
//  The table renderer exactly as it stood at engine commit 6a6a12e, before
//  measurement and drawing were split apart. It exists ONLY as a test oracle:
//  `TableTextDrawingTests` diffs the pixels the new text path produces against
//  the pixels this produced, so a refactor that silently moves a cell, a border
//  or a column fails instead of comparing the new code with itself.
//
//  Do not fix or improve anything in here. It is a frozen copy; if it and the
//  production path must diverge, that is a deliberate change and the test that
//  compares them is where it gets recorded.
//

import AppKit
import Foundation
@testable import MarkdownEngine

func legacyRenderTable(
    _ table: MarkdownStyler.ParsedTable,
    baseFont: NSFont,
    theme: MarkdownEditorTheme,
    codeBackgroundColor: NSColor,
    latex: any LatexRenderer,
    appearance: NSAppearance,
    availableWidth: CGFloat,
    extensions: [any MarkdownExtension] = []
) -> NSImage {
    let columnCount = table.alignments.count
    let cellHPadding: CGFloat = 12
    let cellVPadding: CGFloat = 6
    let borderWidth: CGFloat = 1
    // Resolve under the real appearance: `.withAlphaComponent()` freezes a dynamic color otherwise.
    func mutedColor(alpha: CGFloat) -> NSColor {
        var resolved: NSColor = theme.mutedText
        appearance.performAsCurrentDrawingAppearance {
            resolved = theme.mutedText.usingColorSpace(.sRGB) ?? theme.mutedText
        }
        return resolved.withAlphaComponent(alpha)
    }
    let borderColor = mutedColor(alpha: 0.5)
    let baseLineHeight: CGFloat = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
    let minColumnContentWidth: CGFloat = 16

    // Pre-format every cell so width measurement and drawing share one NSAttributedString.
    let headerCells = table.header.map {
        MarkdownStyler.formattedCellString(
            $0, baseFont: baseFont, header: true, theme: theme,
            codeBackgroundColor: codeBackgroundColor, latex: latex,
            extensions: extensions
        )
    }
    let bodyCells = table.rows.map { row in
        row.map {
            MarkdownStyler.formattedCellString(
                $0, baseFont: baseFont, header: false, theme: theme,
                codeBackgroundColor: codeBackgroundColor, latex: latex,
                extensions: extensions
            )
        }
    }

    // CSS automatic table layout (W3C 17.5.2.2), which is what browser-based
    // editors like Obsidian get for free: each column has a MAXIMUM width
    // (content on one line) and a MINIMUM width (MCW — content may wrap but
    // must not overflow, i.e. the widest unbreakable whitespace-separated
    // segment). Measured segment-by-segment: a too-narrow boundingRect
    // would emergency-break INSIDE words and understate the minimum.
    func widestUnbreakableSegment(_ cell: NSAttributedString) -> CGFloat {
        let str = cell.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var widest: CGFloat = 0
        var segStart = -1
        for i in 0...str.length {
            let isBreak = i == str.length || {
                guard let scalar = Unicode.Scalar(str.character(at: i)) else { return false }
                return whitespace.contains(scalar)
            }()
            if isBreak {
                if segStart >= 0 {
                    let segment = cell.attributedSubstring(from: NSRange(location: segStart, length: i - segStart))
                    widest = max(widest, ceil(segment.size().width))
                    segStart = -1
                }
            } else if segStart < 0 {
                segStart = i
            }
        }
        return widest
    }
    var maxWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
    var minWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
    // `size()` lays a cell out as ONE line, so a cell broken by `<br>`
    // would report the sum of its lines as its natural width.
    func naturalWidth(_ cell: NSAttributedString) -> CGFloat {
        guard cell.string.contains("\n") else { return ceil(cell.size().width) }
        return ceil(cell.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).width)
    }
    func considerCell(_ cell: NSAttributedString, col: Int) {
        maxWidths[col] = max(maxWidths[col], naturalWidth(cell))
        minWidths[col] = max(minWidths[col], widestUnbreakableSegment(cell))
    }
    for (i, cell) in headerCells.enumerated() where i < columnCount {
        considerCell(cell, col: i)
    }
    for row in bodyCells {
        for (i, cell) in row.enumerated() where i < columnCount {
            considerCell(cell, col: i)
        }
    }

    // Distribute the available width:
    // - everything fits on one line → natural (maximum) widths;
    // - too wide → shrink to the available width, but never below a
    //   column's longest unbreakable word; the slack above the minimums is
    //   distributed proportionally to each column's (max − min) stretch;
    // - even the minimums don't fit (many-column tables) → columns stay at
    //   their minimums, the table renders wider than the container, and
    //   the horizontal-scroll overlay takes over as before.
    let chrome = CGFloat(columnCount) * 2 * cellHPadding
        + CGFloat(columnCount + 1) * borderWidth
    let contentAvailable = availableWidth - chrome
    let sumMax = maxWidths.reduce(0, +)
    let sumMin = minWidths.reduce(0, +)
    var columnWidths = maxWidths
    if contentAvailable > 0, sumMax > contentAvailable {
        if sumMin >= contentAvailable {
            columnWidths = minWidths
        } else {
            let extra = contentAvailable - sumMin
            let totalStretch = sumMax - sumMin
            columnWidths = zip(minWidths, maxWidths).map { mn, mx in
                mn + ((mx - mn) / totalStretch * extra).rounded(.down)
            }
        }
    }

    // Per-row heights: each row is as tall as its tallest (wrapped) cell.
    func cellHeight(_ cell: NSAttributedString, col: Int) -> CGFloat {
        let bounds = cell.boundingRect(
            with: NSSize(width: columnWidths[col], height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return ceil(bounds.height)
    }
    let rowCount = 1 + table.rows.count // header + body rows
    var rowContentHeights = [CGFloat](repeating: baseLineHeight, count: rowCount)
    for (i, cell) in headerCells.enumerated() where i < columnCount {
        rowContentHeights[0] = max(rowContentHeights[0], cellHeight(cell, col: i))
    }
    for (rowIdx, row) in bodyCells.enumerated() {
        for (i, cell) in row.enumerated() where i < columnCount {
            rowContentHeights[rowIdx + 1] = max(rowContentHeights[rowIdx + 1], cellHeight(cell, col: i))
        }
    }

    let totalWidth = columnWidths.reduce(0, +)
        + CGFloat(columnCount) * 2 * cellHPadding
        + CGFloat(columnCount + 1) * borderWidth
    let totalHeight = rowContentHeights.reduce(0) { $0 + $1 + 2 * cellVPadding }
        + CGFloat(rowCount + 1) * borderWidth

    let size = NSSize(width: totalWidth, height: totalHeight)

    // Pre-compute layout offsets (top-down coords; drawing runs flipped).
    var columnLeft = [CGFloat](repeating: 0, count: columnCount + 1)
    columnLeft[0] = borderWidth
    for i in 0..<columnCount {
        columnLeft[i + 1] = columnLeft[i] + columnWidths[i] + 2 * cellHPadding + borderWidth
    }
    var rowTop = [CGFloat](repeating: 0, count: rowCount + 1)
    rowTop[0] = borderWidth
    for i in 0..<rowCount {
        rowTop[i + 1] = rowTop[i] + rowContentHeights[i] + 2 * cellVPadding + borderWidth
    }

    let alignments = table.alignments
    let headerFill = mutedColor(alpha: 0.08)

    // Drawn top-down into a flipped context (see `bitmapImage`), so the
    // layout offsets above map 1:1 and AppKit keeps the glyphs upright.
    let draw: () -> Void = {
        // Header row fill
        headerFill.setFill()
        NSBezierPath(rect: NSRect(
            x: borderWidth,
            y: borderWidth,
            width: size.width - 2 * borderWidth,
            height: rowContentHeights[0] + 2 * cellVPadding
        )).fill()

        // Outer border
        borderColor.setStroke()
        let outer = NSBezierPath(rect: NSRect(
            x: borderWidth / 2,
            y: borderWidth / 2,
            width: size.width - borderWidth,
            height: size.height - borderWidth
        ))
        outer.lineWidth = borderWidth
        outer.stroke()

        // Internal separators
        let separators = NSBezierPath()
        separators.lineWidth = borderWidth
        for i in 1..<columnCount {
            let x = columnLeft[i] - borderWidth / 2
            separators.move(to: NSPoint(x: x, y: 0))
            separators.line(to: NSPoint(x: x, y: size.height))
        }
        for i in 1..<rowCount {
            let y = rowTop[i] - borderWidth / 2
            separators.move(to: NSPoint(x: 0, y: y))
            separators.line(to: NSPoint(x: size.width, y: y))
        }
        separators.stroke()

        func drawCell(_ s: NSAttributedString, col: Int, row: Int) {
            guard col < columnCount else { return }
            let cellLeft = columnLeft[col] + cellHPadding
            let cellRight = columnLeft[col + 1] - borderWidth - cellHPadding
            let cellContentWidth = cellRight - cellLeft
            // Align via NSParagraphStyle; word-wrap fills the row height
            // measured above (long words fall back to character breaks).
            let paragraph = NSMutableParagraphStyle()
            switch alignments[col] {
            case .left:   paragraph.alignment = .left
            case .center: paragraph.alignment = .center
            case .right:  paragraph.alignment = .right
            }
            paragraph.lineBreakMode = .byWordWrapping
            let aligned = NSMutableAttributedString(attributedString: s)
            aligned.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: aligned.length)
            )
            let drawRect = NSRect(
                x: cellLeft,
                y: rowTop[row] + cellVPadding,
                width: cellContentWidth,
                height: rowContentHeights[row]
            )
            aligned.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
        }

        for (col, cell) in headerCells.enumerated() {
            drawCell(cell, col: col, row: 0)
        }
        for (rowIdx, row) in bodyCells.enumerated() {
            for (col, cell) in row.enumerated() {
                drawCell(cell, col: col, row: rowIdx + 1)
            }
        }
    }
    return MarkdownStyler.bitmapImage(size: size, appearance: appearance, draw: draw)
}

