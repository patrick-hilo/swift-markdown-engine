//
//  TableImageCacheTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table image cache")
struct TableImageCacheTests {

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

    @Test func differentExtensionRegistriesDoNotShareCacheEntries() throws {
        let source = "| a | b |\n|---|---|\n| ==x== | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let aqua = try #require(NSAppearance(named: .aqua))
        var extConfig = MarkdownEditorConfiguration.default
        extConfig.extensions = [HighlightExtension()]
        // Render under the extension config first, then under the plain config:
        // the second call must be a fresh render, never the cached image (the
        // cell would show a highlight the plain config doesn't have).
        _ = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: extConfig),
            appearance: aqua, availableWidth: 2000)
        let plain = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source),
            appearance: aqua, availableWidth: 2000)
        #expect(plain.rendered, "plain-config table must not reuse the extension-config image")
    }

    @Test func secondRequestIsServedFromCache() throws {
        let source = "| alpha | beta |\n|---|---|\n| 1 | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))

        let first = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)
        let second = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)

        #expect(first.rendered)
        #expect(!second.rendered)
        #expect(first.image === second.image)
    }

    @Test func appearanceChangeRendersFresh() throws {
        let source = "| gamma | delta |\n|---|---|\n| 3 | 4 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        _ = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)
        let darkResult = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: dark, availableWidth: 2000)

        #expect(darkResult.rendered)
    }

    // The key must cover every color renderTable draws with — mutedText paints
    // the border and header fill, so a theme differing only there is a miss.
    @Test func mutedTextChangeRendersFresh() throws {
        let source = "| epsilon | zeta |\n|---|---|\n| 7 | 8 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let aqua = try #require(NSAppearance(named: .aqua))

        var themed = MarkdownEditorConfiguration.default
        themed.theme.mutedText = .systemPink

        _ = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: makeContext(for: source), appearance: aqua, availableWidth: 2000)
        let repainted = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: themed), appearance: aqua, availableWidth: 2000
        )

        #expect(repainted.rendered)
    }

    // NSColor descriptions are not identities: two named dynamic colors sharing
    // a name describe identically. The key must use resolved components instead.
    @Test func sameNamedDynamicColorsDoNotCollide() throws {
        let source = "| eta | theta |\n|---|---|\n| 9 | 10 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let aqua = try #require(NSAppearance(named: .aqua))

        var blueBody = MarkdownEditorConfiguration.default
        blueBody.theme.bodyText = NSColor(name: "body") { _ in .systemBlue }
        var redBody = MarkdownEditorConfiguration.default
        redBody.theme.bodyText = NSColor(name: "body") { _ in .systemRed }

        _ = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: blueBody), appearance: aqua, availableWidth: 2000
        )
        let redRender = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: redBody), appearance: aqua, availableWidth: 2000
        )

        #expect(redRender.rendered)
    }

    // A width change must not leave the previous width's bitmap behind: every
    // live resize step would otherwise add a full set of table bitmaps.
    @Test func newWidthEvictsPreviousWidthOfSameTable() throws {
        let source = "| iota | kappa |\n|---|---|\n| 11 | 12 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))

        _ = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)
        _ = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 1500)
        let backAtOldWidth = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)

        #expect(backAtOldWidth.rendered, "the width-2000 image must have been evicted by the width-1500 render")
    }

    // The cache is process-wide and lives for the whole session; a byte-based
    // cost limit keeps a document with many tables from pinning hundreds of MiB.
    @Test func cacheHasByteCostLimit() {
        #expect(MarkdownStyler.tableImageCache.totalCostLimit > 0)
    }

    // Tables are anti-aliased text plus a few flat colors: an 8-bit RGBA bitmap
    // at the backing scale is enough. The drawing-handler NSImage that AppKit
    // snapshots into a 16-bit float bitmap doubles the memory for nothing.
    @Test func renderedImageIsEightBitBitmapAtBackingScale() throws {
        let source = "| lambda | mu |\n|---|---|\n| 13 | 14 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))

        let image = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000).image
        let rep = try #require(image.representations.first)
        let cgImage = try #require(rep.cgImage(forProposedRect: nil, context: nil, hints: nil))

        #expect(cgImage.bitsPerComponent == 8)
        #expect(cgImage.bitsPerPixel == 32)
        let scale = MarkdownStyler.tableBitmapScale
        #expect(scale >= 1)
        #expect(rep.pixelsWide == Int((image.size.width * scale).rounded(.up)))
        #expect(rep.pixelsHigh == Int((image.size.height * scale).rounded(.up)))
        #expect(rep.size == image.size)
    }

    private func glyphPixelCounts(_ image: NSImage) throws -> (dark: Int, bright: Int) {
        let cgImage = try #require(image.representations.first?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        var dark = 0, bright = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                // Body text is `labelColor` (85 % alpha); count glyph interiors, not anti-aliased edges.
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.6 else { continue }
                if c.brightnessComponent < 0.3 { dark += 1 }
                if c.brightnessComponent > 0.7 { bright += 1 }
            }
        }
        return (dark, bright)
    }

    // The bitmap must actually contain the table: border pixels at the corner
    // and opaque glyph pixels inside. A flipped-context mistake would leave it empty.
    @Test func renderedBitmapContainsBorderAndText() throws {
        let source = "| nu | xi |\n|---|---|\n| MMMM | 16 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))

        let image = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000).image
        let cgImage = try #require(image.representations.first?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let corner = try #require(NSBitmapImageRep(cgImage: cgImage).colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent > 0.1, "outer border must be drawn at the top-left pixel")

        let counts = try glyphPixelCounts(image)
        #expect(counts.dark + counts.bright > 50, "text glyphs must leave opaque pixels, found \(counts)")
    }

    // The bitmap is rendered ahead of display, so dynamic text colors must be
    // resolved under the requested appearance: dark glyphs for aqua, light for dark.
    @Test func textColorFollowsRenderAppearance() throws {
        let source = "| omicron | pi |\n|---|---|\n| MMMM | 17 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        let light = try glyphPixelCounts(MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000).image)
        let darkMode = try glyphPixelCounts(MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: dark, availableWidth: 2000).image)

        #expect(light.dark > 50 && light.bright == 0, "aqua must draw dark text, got \(light)")
        #expect(darkMode.bright > 50 && darkMode.dark == 0, "darkAqua must draw light text, got \(darkMode)")
    }
}
