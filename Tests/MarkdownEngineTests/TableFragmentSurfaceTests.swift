//
//  TableFragmentSurfaceTests.swift
//  MarkdownEngine
//
//  Tripwire for the one thing horizontal table scrolling stands on.
//
//  TextKit 2 gives every layout fragment its own layer-backed subview and draws
//  the fragment into that view's backing store; no public invalidation on
//  NSTextLayoutManager reaches it once the fragment exists. `NativeTextView`
//  therefore repaints a wide table by invalidating the subviews covering its
//  box — geometry only, no class name. That is an undocumented structure, so it
//  gets a test with a real window and the real viewport machinery: if a macOS
//  version stops laying fragments out that way, this fails instead of the
//  reader silently losing the repaint while scrolling a table sideways.
//
//  It cannot live in TableFragmentDrawTests: those call `fragment.draw`
//  directly, which is exactly the mechanism under test being bypassed.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Repainting one table fragment", .serialized)
@MainActor
struct TableFragmentSurfaceTests {

    /// A wide table (12 columns will not fit) followed by a narrow one, so a
    /// repaint that hits everything can be told from one that hits the box.
    private static let source = """
    Intro paragraph.

    | \(Self.wideHeader) |
    |\(String(repeating: "---|", count: 12))
    | \(Self.wideBody) |

    Between the tables.

    | alpha | beta |
    |---|---|
    | one | two |

    Trailing paragraph.
    """
    private static let wideHeader = (1...12).map { "column \($0) heading" }.joined(separator: " | ")
    private static let wideBody = (1...12).map { "body cell \($0)" }.joined(separator: " | ")

    /// `NSTextLayoutManager.delegate` is weak; the harness has to own it.
    @MainActor private static var layoutDelegates: [MarkdownLayoutManagerDelegate] = []

    /// The whole editor stack inside a real window, styled and displayed once —
    /// which is what makes AppKit build the per-fragment rendering surfaces.
    private struct Harness {
        let window: NSWindow
        let textView: NativeTextView
        /// `NativeTextView.layoutBridge` is weak; the harness has to own it.
        let bridge: LayoutBridge
        let wide: TableLayout
        let narrow: TableLayout
        let box: MarkdownTextLayoutFragment.ScrollableBlockBox
    }

    private func makeHarness() throws -> Harness {
        _ = NSApplication.shared
        let width: CGFloat = 520
        let stack = HeightBehaviorStack(viewport: NSSize(width: width, height: 900))
        let tv = stack.textView
        let tlm = try #require(tv.textLayoutManager)
        let delegate = MarkdownLayoutManagerDelegate()
        Self.layoutDelegates.append(delegate)
        tlm.delegate = delegate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = stack.scrollView
        // Off screen but ordered in: AppKit only builds the per-fragment
        // rendering surfaces for a window it actually renders, and an unordered
        // window never renders. Ordered BACK so a test run does not take focus.
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderBack(nil)

        tv.string = Self.source
        let bridge = LayoutBridge(tlm)
        tv.layoutBridge = bridge
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: "Helvetica", fontSize: 15, configuration: .default
        )
        TextStylingService.restyle(
            textView: tv,
            layoutBridge: bridge,
            paragraphCandidates: [NSRange(location: 0, length: (Self.source as NSString).length)],
            baseFont: font,
            paragraphStyle: style,
            caretLocation: (Self.source as NSString).length,
            activeTokenIndices: [],
            wikiLinkIDProvider: { _ in nil }
        )
        tlm.ensureLayout(for: try #require(tlm.textContentManager).documentRange)
        window.display()

        let storage = try #require(tv.textStorage)
        var layouts: [(range: NSRange, layout: TableLayout)] = []
        storage.enumerateAttribute(.tableLayout, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let layout = value as? TableLayout { layouts.append((range, layout)) }
        }
        #expect(layouts.count == 2, "the document must style both of its tables")
        let wideEntry = try #require(layouts.first)
        let narrowEntry = try #require(layouts.last)

        let tcs = try #require(tlm.textContentManager as? NSTextContentStorage)
        let location = try #require(tcs.location(tcs.documentRange.location, offsetBy: wideEntry.range.location))
        let fragment = try #require(tlm.textLayoutFragment(for: location) as? MarkdownTextLayoutFragment)
        let frame = fragment.layoutFragmentFrame
        let origin = CGPoint(x: frame.minX + tv.textContainerOrigin.x,
                             y: frame.minY + tv.textContainerOrigin.y)
        let box = try #require(fragment.scrollableBlockBoxes(at: origin).first,
                               "the first table must be wide enough to scroll")
        return Harness(window: window, textView: tv, bridge: bridge,
                       wide: wideEntry.layout, narrow: narrowEntry.layout, box: box)
    }

    /// The heart of it: the wide table's box is covered by a view of its own
    /// that draws the fragment, and what that view draws follows the offset.
    ///
    /// Drawing is forced through `cacheDisplay` rather than through the window.
    /// A test bundle is not a foreground app, so its windows stay occluded and
    /// AppKit skips their drawing entirely — `display()`, `displayIfNeeded()`
    /// and a flushed CATransaction all leave the fragment untouched, and
    /// `needsDisplay` reads back false however it was set. What the test can
    /// still hold on to is the structure the mechanism needs: a per-fragment
    /// view under the box, drawing it draws the table, and the offset reaches
    /// that drawing. The other half — that `setNeedsDisplay` on such a view is
    /// what makes AppKit redraw it, where nothing on NSTextLayoutManager does —
    /// was measured against the running app and is recorded in
    /// `docs/evidence/2026-09-08-fragment-surface-spike` of the pType repository.
    @Test func theWideTablesSurfaceIsAViewOfItsOwnThatDrawsWithTheOffset() throws {
        let harness = try makeHarness()
        let surfaces = harness.textView.fragmentSurfaceViews(covering: harness.box.box)
        #expect(!surfaces.isEmpty, "TextKit 2 must still put a view under the table's box")

        let narrowBefore = harness.narrow.drawCount
        let wideBefore = harness.wide.drawCount
        let unscrolled = try draw(surfaces, in: harness)
        #expect(harness.wide.drawCount == wideBefore + 1,
                "drawing the table's surface must repaint the table exactly once")
        #expect(harness.narrow.drawCount == narrowBefore,
                "the surface under the wide table must not carry the other table")

        // `invalidateFragmentSurface` is deliberately NOT called here: in an
        // occluded window it marks nothing observable, and `cacheDisplay` below
        // redraws either way, so calling it would only look like it was tested.
        harness.textView.tableHorizontalScrollOffsets[harness.box.sourceID] = 40
        let scrolled = try draw(surfaces, in: harness)
        #expect(harness.wide.drawCount == wideBefore + 2)
        #expect(scrolled != unscrolled, "the offset must reach what the surface draws")
    }

    /// Draws the views covering the table's box and returns their pixels.
    private func draw(_ surfaces: [NSView], in harness: Harness) throws -> Data {
        var data = Data()
        for surface in surfaces where surface.bounds.width > 1 && surface.bounds.height > 1 {
            guard let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { continue }
            surface.cacheDisplay(in: surface.bounds, to: rep)
            if let bytes = rep.bitmapData {
                data.append(bytes, count: rep.bytesPerRow * rep.pixelsHigh)
            }
        }
        #expect(!data.isEmpty, "the surfaces must render something")
        return data
    }

    // MARK: - The scroll gesture

    /// A gesture that is clearly horizontal over a wide table moves the table,
    /// and the document never sees it.
    @Test func aHorizontalGestureOverAWideTableMovesTheTable() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        let point = CGPoint(x: harness.box.box.midX, y: harness.box.box.midY)

        #expect(tv.handleWideTableScroll(step: .began, deltaX: 0, deltaY: 0, at: point) == false,
                "the first step of a gesture carries no delta and decides nothing")
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: -30, deltaY: 1, at: point))
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == 30)
        #expect(tv.handleWideTableScroll(step: .ended, deltaX: 0, deltaY: 0, at: point),
                "the end of a gesture the table owns must not reach the document")
        #expect(tv.handleWideTableScroll(step: .momentum, deltaX: -20, deltaY: 0, at: point),
                "the momentum tail continues the same gesture")
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == 50)
        _ = tv.handleWideTableScroll(step: .momentumEnded, deltaX: 0, deltaY: 0, at: point)
        #expect(tv.wideTableScrollGesture == nil)
    }

    /// A vertical flick over a wide table belongs to the document, including the
    /// steps whose horizontal jitter happens to be the larger delta.
    @Test func aVerticalGestureOverAWideTableStaysWithTheDocument() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        let point = CGPoint(x: harness.box.box.midX, y: harness.box.box.midY)

        _ = tv.handleWideTableScroll(step: .began, deltaX: 0, deltaY: 0, at: point)
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: 1, deltaY: -40, at: point) == false)
        // Jitter mid-gesture: the decision already stands.
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: -9, deltaY: 4, at: point) == false)
        // And the tail, where the vertical delta decays first.
        #expect(tv.handleWideTableScroll(step: .momentum, deltaX: -6, deltaY: 0.2, at: point) == false)
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == nil,
                "the table must not have moved at all")
    }

    /// A diagonal gesture is not horizontal enough to take from the document.
    @Test func aDiagonalGestureStaysWithTheDocument() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        let point = CGPoint(x: harness.box.box.midX, y: harness.box.box.midY)
        _ = tv.handleWideTableScroll(step: .began, deltaX: 0, deltaY: 0, at: point)
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: -30, deltaY: -20, at: point) == false)
    }

    /// Momentum can only continue a gesture, never start one: a tail that drifts
    /// over a table after a flick elsewhere must not grab it.
    @Test func momentumAloneCannotClaimATable() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        let point = CGPoint(x: harness.box.box.midX, y: harness.box.box.midY)
        #expect(tv.handleWideTableScroll(step: .momentum, deltaX: -40, deltaY: 0, at: point) == false)
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == nil)
    }

    /// The offset clamps at both ends, and the step is still taken so the
    /// gesture does not turn into a vertical scroll at the edge.
    @Test func theOffsetClampsAtBothEndsAndTheGestureStaysWithTheTable() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        let point = CGPoint(x: harness.box.box.midX, y: harness.box.box.midY)
        _ = tv.handleWideTableScroll(step: .began, deltaX: 0, deltaY: 0, at: point)
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: -10_000, deltaY: 0, at: point))
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == harness.box.maxOffset)
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: -10_000, deltaY: 0, at: point),
                "at the end the table keeps the gesture instead of handing it on")
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: 10_000, deltaY: 0, at: point))
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == 0)
    }

    /// A stored offset past the current end — the box grew since it was set —
    /// must not swallow the first step of the next gesture.
    @Test func aStaleOffsetDoesNotSwallowTheFirstStep() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        let point = CGPoint(x: harness.box.box.midX, y: harness.box.box.midY)
        tv.tableHorizontalScrollOffsets[harness.box.sourceID] = harness.box.maxOffset + 400
        _ = tv.handleWideTableScroll(step: .began, deltaX: 0, deltaY: 0, at: point)
        #expect(tv.handleWideTableScroll(step: .changed, deltaX: 25, deltaY: 0, at: point))
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == harness.box.maxOffset - 25,
                "the step must move from where the table is drawn, not from the stale value")
    }

    /// A press on the drawn scroller moves the knob under the pointer. Without
    /// it a reader on a mouse could not reach the right-hand columns at all —
    /// the deleted overlay supplied a draggable `NSScroller`.
    @Test func pressingTheScrollerJumpsTheKnobToThePointer() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        let strip = harness.box.scrollerStrip
        let track = MarkdownTextLayoutFragment.scrollerTrack(for: harness.box)
        let drag = try #require(tv.pressWideTableScroller(at: CGPoint(x: track.maxX - 1, y: strip.midY)))
        let offset = try #require(tv.tableHorizontalScrollOffsets[harness.box.sourceID])
        #expect(abs(offset - harness.box.maxOffset) < 1,
                "a press at the end of the track scrolls the table to its end")

        // And dragging it back to the left end scrolls the table back.
        tv.dragWideTableScroller(drag, toPointerX: track.minX)
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == 0)
    }

    /// A press inside the table itself is an ordinary click and must reach the
    /// text — the strip is the only control surface.
    @Test func aPressInTheTableIsNotAScrollerDrag() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        #expect(tv.pressWideTableScroller(at: CGPoint(x: harness.box.box.midX,
                                                      y: harness.box.box.minY + 10)) == nil)
        #expect(tv.tableHorizontalScrollOffsets[harness.box.sourceID] == nil)
    }

    /// The offset the reader scrolled to has to survive the restyle that any
    /// keystroke triggers: the layout and its anchor are rebuilt, the offset is
    /// not part of them.
    @Test func theOffsetSurvivesARestyle() throws {
        let harness = try makeHarness()
        let tv = harness.textView
        tv.tableHorizontalScrollOffsets[harness.box.sourceID] = 60

        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: "Helvetica", fontSize: 15, configuration: .default
        )
        TextStylingService.restyle(
            textView: tv,
            layoutBridge: harness.bridge,
            paragraphCandidates: [NSRange(location: 0, length: (Self.source as NSString).length)],
            baseFont: font,
            paragraphStyle: style,
            caretLocation: (Self.source as NSString).length,
            activeTokenIndices: [],
            wikiLinkIDProvider: { _ in nil }
        )
        let tlm = try #require(tv.textLayoutManager)
        tlm.ensureLayout(for: try #require(tlm.textContentManager).documentRange)
        harness.window.display()

        // The anchor was rebuilt; what matters is that it resolves to the same
        // table, so the kept offset still lands on the table it was scrolled for.
        let storage = try #require(tv.textStorage)
        var sourceIDs: [Int] = []
        storage.enumerateAttribute(.scrollableBlockSourceID, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let id = value as? Int { sourceIDs.append(id) }
        }
        #expect(sourceIDs.contains(harness.box.sourceID))

        // And the table is DRAWN scrolled afterwards: a restyle that reset the
        // offset, or a rebuilt anchor with a new source ID, would put the
        // unscrolled table back on screen without touching the dictionary.
        let surfaces = tv.fragmentSurfaceViews(covering: harness.box.box)
        let afterRestyle = try draw(surfaces, in: harness)
        tv.tableHorizontalScrollOffsets[harness.box.sourceID] = 0
        let unscrolled = try draw(surfaces, in: harness)
        #expect(afterRestyle != unscrolled)
    }
}
