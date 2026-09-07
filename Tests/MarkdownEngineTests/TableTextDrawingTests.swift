//
//  TableTextDrawingTests.swift
//  MarkdownEngine
//
//  Tables drawn as text from a measured layout instead of a cached bitmap:
//  per-cell geometry, agreement with the bitmap path it replaces, and the
//  memory property the whole change exists for.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Tables drawn as text")
struct TableTextDrawingTests {

    private func makeContext(
        for source: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> MarkdownStyler.StylingContext {
        let font = NSFont.systemFont(ofSize: 15)
        return MarkdownStyler.StylingContext(
            nsText: source as NSString,
            tokens: [],
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: configuration,
            wikiLinkIDProvider: { _ in nil }
        )
    }

    private func layout(
        _ source: String,
        width: CGFloat = 2000,
        configuration: MarkdownEditorConfiguration = .default
    ) throws -> TableLayout {
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source, configuration: configuration)
        return MarkdownStyler.measureTable(
            parsed,
            baseFont: ctx.baseFont,
            theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor,
            latex: ctx.services.latex,
            availableWidth: width,
            extensions: ctx.configuration.extensions
        )
    }

    private let simple = "| alpha | beta |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"

    // MARK: - Per-cell geometry

    @Test func everyCellRectSitsInsideTheTable() throws {
        let table = try layout(simple)
        #expect(table.rowCount == 3)
        #expect(table.columnCount == 2)
        for row in 0..<table.rowCount {
            for column in 0..<table.columnCount {
                let rect = try #require(table.cellTextRect(row: row, column: column))
                #expect(rect.minX >= 0)
                #expect(rect.minY >= 0)
                #expect(rect.maxX <= table.size.width + 0.5)
                #expect(rect.maxY <= table.size.height + 0.5)
                #expect(rect.width > 0)
                #expect(rect.height > 0)
            }
        }
    }

    @Test func cellRectsDoNotOverlap() throws {
        let table = try layout(simple)
        var rects: [CGRect] = []
        for row in 0..<table.rowCount {
            for column in 0..<table.columnCount {
                rects.append(try #require(table.cellTextRect(row: row, column: column)))
            }
        }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                #expect(!a.intersects(b), "cell text boxes must not overlap: \(a) vs \(b)")
            }
        }
    }

    @Test func hitTestingRoundTripsThroughEveryCellCentre() throws {
        let table = try layout(simple)
        for row in 0..<table.rowCount {
            for column in 0..<table.columnCount {
                let rect = try #require(table.cellTextRect(row: row, column: column))
                let hit = try #require(table.cell(at: CGPoint(x: rect.midX, y: rect.midY)))
                #expect(hit.row == row)
                #expect(hit.column == column)
            }
        }
    }

    @Test func hitTestingOutsideTheTableFindsNoCell() throws {
        let table = try layout(simple)
        #expect(table.cell(at: CGPoint(x: -1, y: 10)) == nil)
        #expect(table.cell(at: CGPoint(x: 10, y: -1)) == nil)
        #expect(table.cell(at: CGPoint(x: table.size.width + 5, y: 10)) == nil)
        #expect(table.cell(at: CGPoint(x: 10, y: table.size.height + 5)) == nil)
    }

    @Test func cellTextMatchesTheSourceCells() throws {
        let table = try layout(simple)
        #expect(table.cellText(row: 0, column: 0)?.string == "alpha")
        #expect(table.cellText(row: 0, column: 1)?.string == "beta")
        #expect(table.cellText(row: 1, column: 0)?.string == "1")
        #expect(table.cellText(row: 2, column: 1)?.string == "4")
        #expect(table.cellText(row: 3, column: 0) == nil)
    }

    // MARK: - Agreement with the bitmap path

    /// The text path must paint what the table renderer painted BEFORE
    /// measurement and drawing were split apart.
    ///
    /// The oracle is a frozen copy of that renderer (`legacyRenderTable`), not
    /// today's `tableImage` — which now runs the very code under test, so
    /// comparing against it would compare the new path with itself and pass
    /// even if every cell moved.
    @Test(arguments: [
        "| alpha | beta |\n|:--|--:|\n| one | two |\n| three | four |",
        "| centred | right |\n|:-:|--:|\n| a | b |",
        "| only header |\n|---|",
        "| a | b |\n|---|---|\n| | 2 |",
        "| wraps | b |\n|---|---|\n| a sentence long enough to wrap onto several lines | 2 |",
        "| br | b |\n|---|---|\n| one<br>two | 2 |",
        "| esc | b |\n|---|---|\n| a \\| b | 2 |",
        "| code | b |\n|---|---|\n| `x = 1` | **bold** |",
        "| long | b |\n|---|---|\n| Donaudampfschiffahrtsgesellschaftskapitaenspatent | 2 |",
        "| ragged | b | c |\n|---|---|---|\n| 1 |",
    ])
    func textPathPaintsWhatTheFrozenRendererPainted(source: String) throws {
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))

        let oracle = legacyRenderTable(
            parsed,
            baseFont: ctx.baseFont,
            theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor,
            latex: ctx.services.latex,
            appearance: aqua,
            availableWidth: 400,
            extensions: ctx.configuration.extensions
        )
        let table = try layout(source, width: 400)
        #expect(abs(oracle.size.width - table.size.width) < 0.01, "measured width drifted from the frozen renderer")
        #expect(abs(oracle.size.height - table.size.height) < 0.01, "measured height drifted from the frozen renderer")

        let viaText = MarkdownStyler.bitmapImage(size: table.size, appearance: aqua) {
            table.draw(at: .zero)
        }
        let a = try pixels(of: oracle)
        let b = try pixels(of: viaText)
        #expect(a.width == b.width)
        #expect(a.height == b.height)
        #expect(a.bytes == b.bytes, "the text path must paint exactly what the frozen renderer painted")
    }

    /// A guard on the guard: the oracle must be able to fail. Shifting the
    /// drawn table by one point has to break the pixel comparison, otherwise
    /// the test above proves nothing.
    @Test func theFrozenRendererComparisonCanFail() throws {
        let source = "| alpha | beta |\n|---|---|\n| one | two |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let oracle = legacyRenderTable(
            parsed, baseFont: ctx.baseFont, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            appearance: aqua, availableWidth: 400, extensions: ctx.configuration.extensions
        )
        let table = try layout(source, width: 400)
        let shifted = MarkdownStyler.bitmapImage(size: table.size, appearance: aqua) {
            table.draw(at: CGPoint(x: 1, y: 0))
        }
        #expect(try pixels(of: oracle).bytes != pixels(of: shifted).bytes)
    }

    /// Absolute cell geometry, so a uniform displacement of every cell — which
    /// no self-consistency check can see — fails here.
    @Test func cellBoxesSitAtTheirDocumentedOffsets() throws {
        let table = try layout(simple, width: 600)
        let border = TableLayout.borderWidth
        let hPad = TableLayout.cellHPadding
        let vPad = TableLayout.cellVPadding
        let first = try #require(table.cellTextRect(row: 0, column: 0))
        #expect(abs(first.minX - (border + hPad)) < 0.01, "first cell starts one border + one padding in")
        #expect(abs(first.minY - (border + vPad)) < 0.01)
        #expect(abs(first.width - table.columnWidths[0]) < 0.01)
        #expect(abs(first.height - table.rowContentHeights[0]) < 0.01)

        let second = try #require(table.cellTextRect(row: 0, column: 1))
        let expectedSecondX = border + table.columnWidths[0] + 2 * hPad + border + hPad
        #expect(abs(second.minX - expectedSecondX) < 0.01, "second column starts after the first column's box and separator")

        let secondRow = try #require(table.cellTextRect(row: 1, column: 0))
        let expectedSecondY = border + table.rowContentHeights[0] + 2 * vPad + border + vPad
        #expect(abs(secondRow.minY - expectedSecondY) < 0.01)

        let lastX = table.columnLeft[table.columnCount]
        #expect(abs(table.size.width - lastX) < 0.01, "the table ends where the last column's box ends")
    }

    @Test func drawingAtAnOriginTranslatesEveryPixel() throws {
        let table = try layout(simple, width: 600)
        let aqua = try #require(NSAppearance(named: .aqua))
        let offset = CGPoint(x: 7, y: 5)
        let padded = CGSize(width: table.size.width + offset.x, height: table.size.height + offset.y)

        let atOrigin = try pixels(of: MarkdownStyler.bitmapImage(size: padded, appearance: aqua) {
            table.draw(at: .zero)
        })
        let translated = try pixels(of: MarkdownStyler.bitmapImage(size: padded, appearance: aqua) {
            table.draw(at: offset)
        })
        #expect(atOrigin.bytes != translated.bytes, "an origin must actually move the table")

        // The translated table's top-left corner region must be empty where the
        // untranslated one has its border.
        let scale = MarkdownStyler.tableBitmapScale
        let probe = CGPoint(x: 1, y: 1)
        let px = Int(probe.x * scale), py = Int(probe.y * scale)
        #expect(atOrigin.alpha(x: px, y: py) > 0, "table must paint its own top-left corner")
        #expect(translated.alpha(x: px, y: py) == 0, "translated table must leave the origin corner clear")
    }

    // MARK: - Memory

    /// The reason the change exists: a layout costs the table's text, a bitmap
    /// costs its pixel area. On a table of this size the gap is two orders of
    /// magnitude, and it widens with the table.
    @Test func aLayoutCostsFarLessThanItsBitmap() throws {
        let source = "| heading one | heading two | heading three |\n|---|---|---|\n"
            + (1...20).map { "| row \($0) cell a | row \($0) cell b | row \($0) cell c |" }.joined(separator: "\n")
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let table = try layout(source, width: 800)
        let image = MarkdownStyler.tableImage(
            for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 800
        ).image
        let cgImage = try #require(image.representations.first?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmapBytes = cgImage.bytesPerRow * cgImage.height
        #expect(table.approximateByteCount * 20 < bitmapBytes,
                "layout \(table.approximateByteCount) B vs bitmap \(bitmapBytes) B")
    }

    // MARK: - Appearance independence

    /// Measurement must not depend on the appearance — that is what lets a
    /// dark-mode switch repaint without re-measuring or re-styling.
    @Test func measurementIsIdenticalInLightAndDarkMode() throws {
        let source = "| alpha | beta |\n|---|---|\n| one | two |"
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        var lightTable: TableLayout?
        var darkTable: TableLayout?
        aqua.performAsCurrentDrawingAppearance { lightTable = try? self.layout(source, width: 600) }
        dark.performAsCurrentDrawingAppearance { darkTable = try? self.layout(source, width: 600) }
        let light = try #require(lightTable)
        let night = try #require(darkTable)
        #expect(light.size == night.size)
        #expect(light.columnWidths == night.columnWidths)
        #expect(light.rowContentHeights == night.rowContentHeights)
    }

    /// …while the drawing still differs, because the cell colors stay dynamic.
    @Test func theSameLayoutDrawsDifferentlyInDarkMode() throws {
        let table = try layout(simple, width: 600)
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try pixels(of: MarkdownStyler.bitmapImage(size: table.size, appearance: aqua) {
            table.draw(at: .zero)
        })
        let night = try pixels(of: MarkdownStyler.bitmapImage(size: table.size, appearance: dark) {
            table.draw(at: .zero)
        })
        #expect(light.bytes != night.bytes, "one layout must repaint for the current appearance")
    }

    // MARK: - Cache

    // The layout cache is process-wide and these tests run in parallel with
    // every other suite, so none of them may clear it — a sibling would lose
    // its entry between two lookups. Each test uses a source string no other
    // test uses instead, which isolates its entries by key.

    @Test func secondMeasurementIsServedFromCache() throws {
        let source = "| cached-second-request | table |\n|---|---|\n| 1 | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let first = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 1234)
        let second = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 1234)
        #expect(first.measured)
        #expect(!second.measured)
        #expect(first.layout === second.layout)
    }

    /// A width change must evict the previous width's entry, or a live resize
    /// leaves one layout per intermediate width behind.
    @Test func aNewWidthEvictsThePreviousWidthsLayout() throws {
        let source = "| cached-width-eviction | table |\n|---|---|\n| 1 | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        _ = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 2000)
        _ = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 1500)
        let backAtOldWidth = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 2000)
        #expect(backAtOldWidth.measured, "the 2000-wide layout should have been evicted by the 1500-wide one")
    }

    // MARK: - What the styler emits

    private func styledTableAnchor(
        _ text: String,
        drawsAsText: Bool
    ) throws -> (range: NSRange, attributes: [NSAttributedString.Key: Any]) {
        _ = NSApplication.shared
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let font = NSFont.systemFont(ofSize: 15)
        let context = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
        var scoped = context
        scoped.drawsTablesAsText = drawsAsText
        let attributes = MarkdownStyler.styleTables(scoped)
        return try #require(attributes.first { $0.attributes[.latexIsBlock] != nil })
    }

    /// A narrow table's anchor must carry the measured layout and no bitmap.
    /// `.latexBounds` still describes the same rect, so the fragment places it
    /// exactly where the image path placed the image.
    @Test func theStylerAnchorsANarrowTableOnItsLayout() throws {
        let anchor = try styledTableAnchor("| a | b |\n|---|---|\n| 1 | 2 |", drawsAsText: true)
        let table = try #require(anchor.attributes[.tableLayout] as? TableLayout)
        #expect(anchor.attributes[.latexImage] == nil, "the text path must not also retain a bitmap")
        let bounds = try #require(anchor.attributes[.latexBounds] as? NSValue).rectValue
        #expect(abs(bounds.width - table.size.width) < 0.5)
        #expect(abs(bounds.height - table.size.height) < 0.5)
    }

    /// With the switch off the anchor goes back to a bitmap, so the comparison
    /// build measures the path it is supposed to measure.
    @Test func theSwitchRestoresTheBitmapAnchor() throws {
        let anchor = try styledTableAnchor("| a | b |\n|---|---|\n| 1 | 2 |", drawsAsText: false)
        #expect(anchor.attributes[.latexImage] is NSImage)
        #expect(anchor.attributes[.tableLayout] == nil)
    }

    /// Stage 1 keeps wide tables on the overlay, which hosts an NSImageView —
    /// so a wide table still needs its bitmap even with the switch on.
    @Test func aWideTableStillCarriesItsOverlayBitmap() throws {
        let wide = "| " + (1...12).map { "column \($0) heading" }.joined(separator: " | ") + " |\n"
            + "|" + String(repeating: "---|", count: 12) + "\n"
            + "| " + (1...12).map { "body cell \($0)" }.joined(separator: " | ") + " |"
        let anchor = try styledTableAnchor(wide, drawsAsText: true)
        #expect(anchor.attributes[.scrollableBlockNaturalWidth] != nil, "table should be wide at the 500pt fallback width")
        #expect(anchor.attributes[.latexImage] is NSImage)
        #expect(anchor.attributes[.tableLayout] == nil)
    }

    // MARK: - LaTeX in cells is appearance-specific

    /// A renderer that bakes the theme's appearance-specific ink colour into
    /// the attachment, the way SwiftMath does.
    private final class AppearanceBakingLatexRenderer: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink = dark ? theme.latexDarkModeText : theme.latexLightModeText
            let size = CGSize(width: 10, height: 10)
            let image = MarkdownStyler.bitmapImage(size: size, appearance: .currentDrawing()) {
                ink.setFill()
                NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            }
            return LatexRenderResult(image: image, size: size, baselineOffset: 0)
        }
    }

    private func latexContext(_ source: String) -> MarkdownStyler.StylingContext {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(latex: AppearanceBakingLatexRenderer())
        return makeContext(for: source, configuration: configuration)
    }

    /// A cell's LaTeX attachment is rasterized with the ink colour of whatever
    /// appearance was current, so the cached layout is NOT appearance-neutral
    /// for such a table. Switching appearance must re-measure it, or the
    /// formula keeps light-mode ink on a dark table.
    @Test func aTableWithLatexIsReMeasuredForTheOtherAppearance() throws {
        let source = "| cached-latex-appearance | b |\n|---|---|\n| $x^2$ | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = latexContext(source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        var light: (layout: TableLayout, measured: Bool)?
        var night: (layout: TableLayout, measured: Bool)?
        aqua.performAsCurrentDrawingAppearance {
            light = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 600)
        }
        dark.performAsCurrentDrawingAppearance {
            night = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 600)
        }
        #expect(try #require(light).measured)
        #expect(try #require(night).measured, "a table holding LaTeX must not reuse the other appearance's layout")
        #expect(try #require(light).layout !== #require(night).layout)
    }

    /// …and a table WITHOUT LaTeX must still be reused across appearances,
    /// which is what makes a dark-mode switch free for ordinary tables.
    @Test func aTableWithoutLatexIsSharedAcrossAppearances() throws {
        let source = "| cached-appearance-shared | b |\n|---|---|\n| one | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = latexContext(source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        var night: (layout: TableLayout, measured: Bool)?
        aqua.performAsCurrentDrawingAppearance {
            _ = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 600)
        }
        dark.performAsCurrentDrawingAppearance {
            night = MarkdownStyler.tableLayout(for: source, parsed: parsed, ctx: ctx, availableWidth: 600)
        }
        #expect(!(try #require(night).measured), "a LaTeX-free table must survive an appearance switch")
    }

    /// Two themes that differ only in a colour must not share a layout. The
    /// cells carry the theme's colours, so a shared entry would paint the old
    /// theme's text. Keyed on resolved components, not instance identity —
    /// NSColor addresses get reused.
    @Test func themesDifferingOnlyInAColourDoNotShareALayout() throws {
        let source = "| cached-theme-collision | b |\n|---|---|\n| one | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))

        var first = MarkdownEditorConfiguration.default
        first.theme.bodyText = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1)
        var second = MarkdownEditorConfiguration.default
        second.theme.bodyText = NSColor(srgbRed: 0.90, green: 0.80, blue: 0.70, alpha: 1)

        _ = MarkdownStyler.tableLayout(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: first), availableWidth: 600)
        let other = MarkdownStyler.tableLayout(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: second), availableWidth: 600)
        #expect(other.measured, "a different body-text colour must not reuse the first theme's layout")
    }

    // MARK: - Pixel helper

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let bytesPerRow: Int

        func alpha(x: Int, y: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            // premultipliedFirst / byteOrder32Little → BGRA in memory, alpha last.
            return bytes[y * bytesPerRow + x * 4 + 3]
        }
    }

    private func pixels(of image: NSImage) throws -> Pixels {
        let cgImage = try #require(image.representations.first?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let context = try #require(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, height: height, bytes: bytes, bytesPerRow: bytesPerRow)
    }
}
