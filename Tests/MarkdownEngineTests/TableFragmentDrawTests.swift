//
//  TableFragmentDrawTests.swift
//  MarkdownEngine
//
//  The production draw path for a table: a real text view, styled through
//  `TextStylingService`, laid out, and drawn into a bitmap through
//  `MarkdownTextLayoutFragment`. The unit tests around `TableLayout` prove the
//  geometry; this proves the fragment actually puts it on screen.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Table drawing through the layout fragment")
@MainActor
struct TableFragmentDrawTests {

    private let source = """
    Intro paragraph.

    | alpha | beta |
    |---|---|
    | one | two |
    | three | four |

    Trailing paragraph.
    """

    /// Styles `text` in a real text view and returns it, laid out.
    ///
    /// The layout-manager delegate goes in BEFORE the content: it is what vends
    /// `MarkdownTextLayoutFragment`, and fragments already built for the old
    /// delegate are not replaced by a later `invalidateLayout`. Install it late
    /// and the whole suite silently measures an empty bitmap.
    private func styledTextView(_ text: String, width: CGFloat = 700) throws -> NativeTextView {
        let stack = HeightBehaviorStack(viewport: NSSize(width: width, height: 900))
        let tv = stack.textView
        let tlm = try #require(tv.textLayoutManager)
        let delegate = MarkdownLayoutManagerDelegate()
        Self.layoutDelegates.append(delegate)   // the property is weak
        tlm.delegate = delegate

        tv.string = text
        let bridge = LayoutBridge(tlm)
        tv.layoutBridge = bridge
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: "Helvetica", fontSize: 15, configuration: .default
        )
        TextStylingService.restyle(
            textView: tv,
            layoutBridge: bridge,
            paragraphCandidates: [NSRange(location: 0, length: (text as NSString).length)],
            baseFont: font,
            paragraphStyle: style,
            caretLocation: (text as NSString).length,
            activeTokenIndices: [],
            wikiLinkIDProvider: { _ in nil }
        )
        tlm.ensureLayout(for: try #require(tlm.textContentManager).documentRange)
        return tv
    }

    /// `NSTextLayoutManager.delegate` is weak; the harness has to own it.
    @MainActor private static var layoutDelegates: [MarkdownLayoutManagerDelegate] = []

    /// Draws every layout fragment of `tv` into a bitmap, exactly the way the
    /// viewport layout controller does — so `MarkdownTextLayoutFragment.draw`
    /// and with it `drawTableLayouts` really run.
    private func renderFragments(of tv: NativeTextView, width: CGFloat = 700) throws -> NSBitmapImageRep {
        let tlm = try #require(tv.textLayoutManager)
        var markdownFragments = 0
        let height = max(1, tlm.usageBoundsForTextContainer.height)
        let size = NSSize(width: width, height: height)
        let image = MarkdownStyler.bitmapImage(size: size, appearance: .currentDrawing()) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            tlm.enumerateTextLayoutFragments(
                from: tlm.documentRange.location, options: [.ensuresLayout]
            ) { fragment in
                if fragment is MarkdownTextLayoutFragment { markdownFragments += 1 }
                let frame = fragment.layoutFragmentFrame
                fragment.draw(at: frame.origin, in: context)
                return true
            }
        }
        #expect(markdownFragments > 0, "the harness must exercise MarkdownTextLayoutFragment")
        let cgImage = try #require(image.representations.first?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: cgImage)
    }

    /// Number of pixels the fragments actually painted on.
    ///
    /// Keyed on alpha, not brightness: the bitmap is transparent where nothing
    /// was drawn, and glyph and border colours arrive premultiplied, so their
    /// brightness is not a reliable discriminator. The 0.2 floor keeps the
    /// header row's 8 %-alpha fill out of the count, leaving glyphs and the
    /// 50 %-alpha rules.
    private func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        var inked = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.2 { inked += 1 }
            }
        }
        return inked
    }

    /// The anchor must carry a layout — otherwise the rest of this suite would
    /// be testing the bitmap path by accident.
    @Test func theStyledDocumentCarriesATableLayout() throws {
        let tv = try styledTextView(source)
        let storage = try #require(tv.textStorage)
        var found: TableLayout?
        storage.enumerateAttribute(.tableLayout, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let layout = value as? TableLayout { found = layout; stop.pointee = true }
        }
        let layout = try #require(found, "a narrow table must be anchored on a measured layout")
        #expect(layout.columnCount == 2)
        #expect(layout.rowCount == 3)
        #expect(storage.attribute(.latexImage, at: 0, longestEffectiveRange: nil,
                                  in: NSRange(location: 0, length: storage.length)) == nil)
    }

    /// The fragment must paint the table. Without the `.tableLayout` branch in
    /// `drawLatexImages` the table's source is collapsed to nothing and only
    /// the two paragraphs would reach the bitmap.
    @Test func theFragmentPaintsTheTable() throws {
        let withTable = inkedPixels(try renderFragments(of: try styledTextView(source)))
        let proseOnly = inkedPixels(try renderFragments(
            of: try styledTextView("Intro paragraph.\n\nTrailing paragraph.")))
        #expect(withTable > proseOnly + 500,
                "the table must add ink (table \(withTable) vs prose-only \(proseOnly))")
    }

    /// The grid itself must be there, not just the cell text: count the long
    /// horizontal runs of border pixels that only a drawn table produces.
    @Test func theFragmentPaintsTheGridLines() throws {
        let rep = try renderFragments(of: try styledTextView(source))
        var longRuns = 0
        for y in 0..<rep.pixelsHigh {
            var run = 0
            for x in 0..<rep.pixelsWide {
                let inked = (rep.colorAt(x: x, y: y).map { $0.alphaComponent > 0.2 } ?? false)
                run = inked ? run + 1 : 0
                if run == 200 { longRuns += 1 }
            }
        }
        #expect(longRuns >= 3, "expected the table's horizontal rules, found \(longRuns)")
    }

    /// The table's ink must land inside the text container, not spill out of
    /// it — the failure mode the hidden-source kern guards against.
    @Test func theTableStaysInsideTheContainer() throws {
        let width: CGFloat = 700
        let rep = try renderFragments(of: try styledTextView(source, width: width), width: width)
        var maxInkedX = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.2 else { continue }
                maxInkedX = max(maxInkedX, x)
            }
        }
        let scale = CGFloat(rep.pixelsWide) / width
        #expect(CGFloat(maxInkedX) / scale <= width + 0.5)
    }
}
