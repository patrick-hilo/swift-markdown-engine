//
//  TableLayout.swift
//  MarkdownEngine
//
//  Measured geometry and formatted cell text for one GFM table.
//
//  This is what replaces the rendered bitmap: column widths, row heights and
//  one NSAttributedString per cell. Memory scales with the table's text, not
//  with its pixel area, and the theme colors stay dynamic because the cells
//  are drawn on demand instead of rasterized ahead of display.
//

import AppKit
import Foundation

/// Geometry + cell text for one table, measured at a fixed available width.
///
/// A reference type: it is carried on the table's anchor character as an
/// attribute and shared by the fragment that draws it, so copying it per
/// attribute lookup would defeat the point.
final class TableLayout: NSObject {

    /// Horizontal padding between a column separator and its cell text.
    static let cellHPadding: CGFloat = 12
    /// Vertical padding above and below a row's cell text.
    static let cellVPadding: CGFloat = 6
    /// Width of the outer border and of every internal separator.
    static let borderWidth: CGFloat = 1

    /// Content width of each column, excluding padding and borders.
    let columnWidths: [CGFloat]
    /// Content height of each row (header first), excluding padding and borders.
    let rowContentHeights: [CGFloat]
    /// Left edge of each column's cell box; `columnCount + 1` entries.
    let columnLeft: [CGFloat]
    /// Top edge of each row's cell box; `rowCount + 1` entries.
    let rowTop: [CGFloat]
    /// Full drawn size of the table in points.
    let size: CGSize
    let alignments: [MarkdownStyler.TableAlignment]
    let headerCells: [NSAttributedString]
    let bodyCells: [[NSAttributedString]]

    /// Kept dynamic on purpose: border and header fill are derived from this
    /// at draw time, so an appearance change repaints correctly without a
    /// restyle. Resolving here would freeze the light-mode variant into the
    /// layout the way the bitmap path had to.
    let mutedText: NSColor

    /// How often this layout has been drawn.
    ///
    /// The only way to observe from outside AppKit whether a repaint really
    /// reached a layout fragment, which is what `TableFragmentSurfaceTests`
    /// has to know. Per instance on purpose: a process-wide counter would be
    /// shared between tests running in parallel.
    private(set) var drawCount = 0

    var columnCount: Int { alignments.count }
    var rowCount: Int { 1 + bodyCells.count }

    init(
        columnWidths: [CGFloat],
        rowContentHeights: [CGFloat],
        columnLeft: [CGFloat],
        rowTop: [CGFloat],
        size: CGSize,
        alignments: [MarkdownStyler.TableAlignment],
        headerCells: [NSAttributedString],
        bodyCells: [[NSAttributedString]],
        mutedText: NSColor
    ) {
        self.columnWidths = columnWidths
        self.rowContentHeights = rowContentHeights
        self.columnLeft = columnLeft
        self.rowTop = rowTop
        self.size = size
        self.alignments = alignments
        self.headerCells = headerCells
        self.bodyCells = bodyCells
        self.mutedText = mutedText
    }

    /// Rough retained size, used as the layout cache's cost: two bytes per
    /// UTF-16 unit, a flat per-cell allowance for the attribute runs, the
    /// measurement arrays, and any rasterized attachment a cell carries.
    ///
    /// The attachments matter: an ordinary table's layout is a few kilobytes,
    /// but a cell holding inline LaTeX carries a real bitmap, and a cost
    /// function that ignored it would let the cache hold far more bytes than
    /// its cap allows.
    var approximateByteCount: Int {
        var bytes = (columnWidths.count + rowContentHeights.count
                     + columnLeft.count + rowTop.count) * MemoryLayout<CGFloat>.size
        func account(_ cell: NSAttributedString) {
            bytes += cell.length * 2 + 128
            cell.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: cell.length), options: []
            ) { value, _, _ in
                guard let image = (value as? NSTextAttachment)?.image else { return }
                guard let cgImage = image.representations.first?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                bytes += cgImage.bytesPerRow * cgImage.height
            }
        }
        headerCells.forEach(account)
        bodyCells.forEach { $0.forEach(account) }
        return bytes
    }

    // MARK: - Cell geometry

    /// Rect of the cell's text box (inside padding and borders), in the
    /// layout's own top-down coordinate space.
    ///
    /// `row` is 0 for the header and `1...` for body rows.
    func cellTextRect(row: Int, column: Int) -> CGRect? {
        guard column >= 0, column < columnCount, row >= 0, row < rowCount else { return nil }
        let left = columnLeft[column] + Self.cellHPadding
        let right = columnLeft[column + 1] - Self.borderWidth - Self.cellHPadding
        return CGRect(
            x: left,
            y: rowTop[row] + Self.cellVPadding,
            width: max(0, right - left),
            height: rowContentHeights[row]
        )
    }

    /// The cell containing `point`, given in the layout's own coordinate
    /// space. Returns `nil` on a border or outside the table.
    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        var column: Int?
        for i in 0..<columnCount where point.x >= columnLeft[i] && point.x < columnLeft[i + 1] {
            column = i
            break
        }
        var row: Int?
        for i in 0..<rowCount where point.y >= rowTop[i] && point.y < rowTop[i + 1] {
            row = i
            break
        }
        guard let column, let row else { return nil }
        return (row, column)
    }

    /// The formatted string drawn in a cell, or `nil` when the coordinates
    /// fall outside the table.
    func cellText(row: Int, column: Int) -> NSAttributedString? {
        guard column >= 0, column < columnCount else { return nil }
        if row == 0 {
            return column < headerCells.count ? headerCells[column] : nil
        }
        let bodyIndex = row - 1
        guard bodyIndex >= 0, bodyIndex < bodyCells.count else { return nil }
        let cells = bodyCells[bodyIndex]
        return column < cells.count ? cells[column] : nil
    }

    // MARK: - Drawing

    /// Draws the table with its top-left corner at `origin` in the current
    /// graphics context, which must be flipped (top-down), as both the text
    /// view's fragment drawing and `MarkdownStyler.bitmapImage` are.
    ///
    /// `horizontalOffset` shifts the content left for a wide table that
    /// scrolls inside a narrower box; the caller is responsible for clipping.
    ///
    /// `clip`, when given, is the visible rect in the same space as `origin`.
    /// Rows and columns outside it are skipped. That matters for a wide table:
    /// it repaints on every scroll event, and laying out the cells of the
    /// columns parked outside the box costs the same as the visible ones —
    /// several milliseconds per frame on a table with many rows.
    func draw(at origin: CGPoint, horizontalOffset: CGFloat = 0, clip: CGRect? = nil, decorate: ((Int, Int, NSAttributedString) -> NSAttributedString)? = nil) {
        drawCount += 1
        let border = Self.borderWidth
        let x0 = origin.x - horizontalOffset
        let y0 = origin.y

        // Dynamic colors resolve against whatever appearance is current while
        // drawing, so light/dark switches need no restyle.
        let resolvedMuted = mutedText.usingColorSpace(.sRGB) ?? mutedText
        let borderColor = resolvedMuted.withAlphaComponent(0.5)
        let headerFill = resolvedMuted.withAlphaComponent(0.08)

        headerFill.setFill()
        NSBezierPath(rect: NSRect(
            x: x0 + border,
            y: y0 + border,
            width: size.width - 2 * border,
            height: rowContentHeights[0] + 2 * Self.cellVPadding
        )).fill()

        borderColor.setStroke()
        let outer = NSBezierPath(rect: NSRect(
            x: x0 + border / 2,
            y: y0 + border / 2,
            width: size.width - border,
            height: size.height - border
        ))
        outer.lineWidth = border
        outer.stroke()

        let separators = NSBezierPath()
        separators.lineWidth = border
        if columnCount > 1 {
            for i in 1..<columnCount {
                let x = x0 + columnLeft[i] - border / 2
                separators.move(to: NSPoint(x: x, y: y0))
                separators.line(to: NSPoint(x: x, y: y0 + size.height))
            }
        }
        if rowCount > 1 {
            for i in 1..<rowCount {
                let y = y0 + rowTop[i] - border / 2
                separators.move(to: NSPoint(x: x0, y: y))
                separators.line(to: NSPoint(x: x0 + size.width, y: y))
            }
        }
        separators.stroke()

        for row in 0..<rowCount where rowIsVisible(row, y0: y0, clip: clip) {
            for column in 0..<columnCount where columnIsVisible(column, x0: x0, clip: clip) {
                guard let cell = cellText(row: row, column: column),
                      var rect = cellTextRect(row: row, column: column) else { continue }
                rect.origin.x += x0
                rect.origin.y += y0
                Self.draw(cell: decorate?(row, column, cell) ?? cell, in: rect, alignment: alignments[column])
            }
        }
    }

    /// Whether a row's band reaches into `clip`. Internal so the culling can be
    /// asserted directly: the pixel tests prove it changes nothing, this proves
    /// it actually leaves something out.
    func rowIsVisible(_ row: Int, y0: CGFloat, clip: CGRect?) -> Bool {
        guard let clip else { return true }
        return y0 + rowTop[row + 1] > clip.minY && y0 + rowTop[row] < clip.maxY
    }

    /// Whether a column's band reaches into `clip`; see `rowIsVisible`.
    func columnIsVisible(_ column: Int, x0: CGFloat, clip: CGRect?) -> Bool {
        guard let clip else { return true }
        return x0 + columnLeft[column + 1] > clip.minX && x0 + columnLeft[column] < clip.maxX
    }

    /// Applies the column's alignment and word wrapping, then draws the cell.
    /// Shared by the text path and the legacy bitmap path so both wrap
    /// identically to what `cellHeight` measured.
    static func draw(cell: NSAttributedString, in rect: CGRect, alignment: MarkdownStyler.TableAlignment) {
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left:   paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right:  paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        let aligned = NSMutableAttributedString(attributedString: cell)
        aligned.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: aligned.length)
        )
        aligned.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
    }
}
