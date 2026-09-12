import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Tables outside the reading column", .serialized)
@MainActor
struct TableAvailableWidthTests {
    nonisolated private static let wideSource = "Intro.\n\n| " + (1...24).map { "column\($0)" }.joined(separator: " | ")
        + " |\n|" + String(repeating: "---|", count: 24)
        + "\n| " + (1...24).map { "value\($0)" }.joined(separator: " | ") + " |\n\nTail."

    @MainActor private final class Harness {
        let stack: HeightBehaviorStack
        let delegate = MarkdownLayoutManagerDelegate()
        let bridge: LayoutBridge
        let source: String
        var view: NativeTextView { stack.textView }

        init(source: String = wideSource, width: CGFloat = 1000, gutter: CGFloat = 32, enabled: Bool = true) throws {
            _ = NSApplication.shared
            self.source = source
            stack = HeightBehaviorStack(viewport: NSSize(width: width, height: 900))
            let layout = try #require(stack.textView.textLayoutManager)
            bridge = LayoutBridge(layout)
            layout.delegate = delegate
            view.layoutBridge = bridge
            view.configuration.tablesUseAvailableWidth = enabled
            view.configuration.textInsets = TextInsets(horizontal: gutter, vertical: 0)
            view.textContainer?.lineFragmentPadding = 0
            view.applyReadingWidth(400)
            view.string = source
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            restyle()
        }

        func restyle() {
            let (font, style) = TextStylingService.makeBaseFontAndStyle(
                fontName: "Helvetica", fontSize: 15, configuration: view.configuration
            )
            TextStylingService.restyle(
                textView: view, layoutBridge: bridge,
                paragraphCandidates: [NSRange(location: 0, length: (source as NSString).length)],
                baseFont: font, paragraphStyle: style,
                caretLocation: (source as NSString).length, activeTokenIndices: [],
                wikiLinkIDProvider: { _ in nil }, configuration: view.configuration
            )
            if let layout = view.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        }

        func tableFragment() throws -> MarkdownTextLayoutFragment {
            let storage = try #require(view.textStorage)
            var anchor: Int?
            storage.enumerateAttribute(.tableLayout, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value is TableLayout { anchor = range.location; stop.pointee = true }
            }
            let index = try #require(anchor)
            #expect(storage.attribute(.latexImage, at: index, effectiveRange: nil) == nil)
            let layout = try #require(view.textLayoutManager)
            let content = try #require(layout.textContentManager)
            let location = try #require(content.location(content.documentRange.location, offsetBy: index))
            return try #require(layout.textLayoutFragment(for: location) as? MarkdownTextLayoutFragment)
        }

        func box() throws -> MarkdownTextLayoutFragment.ScrollableBlockBox {
            let fragment = try tableFragment()
            let origin = fragment.layoutFragmentFrame.origin
            return try #require(fragment.scrollableBlockBoxes(at: CGPoint(
                x: origin.x + view.textContainerOrigin.x, y: origin.y + view.textContainerOrigin.y
            )).first)
        }
    }

    @Test func wideTableUsesOuterGuttersWhileProseKeepsReadingWidth() throws {
        let h = try Harness()
        let box = try h.box()
        #expect(h.view.frame.width == 1000)
        #expect(h.view.frame.minX == 0)
        #expect(h.view.textContainer?.size.width == 400)
        #expect(h.view.textContainerOrigin.x == 300)
        #expect(abs(box.box.minX - 32) < 1)
        #expect(abs(box.box.maxX - 968) < 1)
        #expect(box.maxOffset > 0)
        let fragment = try h.tableFragment()
        #expect(fragment.renderingSurfaceBounds.minX < -250)
        #expect(fragment.renderingSurfaceBounds.width >= box.box.width)
    }

    @Test func oddViewportWidthKeepsExactProseMeasure() throws {
        let h = try Harness(width: 1001)
        #expect(h.view.frame.width - 2 * h.view.textContainerInset.width == 400)
        #expect(abs(h.view.textContainerOrigin.x - h.view.textContainerInset.width) <= 0.5)
        let box = try h.box()
        #expect(abs(box.box.minX - 32) <= 0.5)
    }

    @Test func appKitSurfaceSpansAndDrawsBothOuterMargins() throws {
        let h = try Harness()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = h.stack.scrollView
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        h.restyle()
        window.display()
        let box = try h.box()
        let surfaces = h.view.fragmentSurfaceViews(covering: box.box)
        let surface = try #require(surfaces.filter { surface in
            let frame = surface.convert(surface.bounds, to: h.view)
            return frame.minX <= box.box.minX + 1 && frame.maxX >= box.box.maxX - 1
                && frame.minY <= box.box.minY + 1 && frame.maxY >= box.box.maxY - 1
        }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height },
        "AppKit's cached surface must cover the table beyond both prose margins")
        let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
        for x in [box.box.minX + 10, box.box.maxX - 30] {
            let strip = surface.convert(CGRect(x: x, y: box.box.minY, width: 20, height: box.box.height), from: h.view)
            var ink = 0
            for y in max(0, Int((strip.minY - surface.bounds.minY) * scale))..<min(bitmap.pixelsHigh, Int((strip.maxY - surface.bounds.minY) * scale)) {
                for pixelX in max(0, Int((strip.minX - surface.bounds.minX) * scale))..<min(bitmap.pixelsWide, Int((strip.maxX - surface.bounds.minX) * scale)) {
                    if (bitmap.colorAt(x: pixelX, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
                }
            }
            #expect(ink > 20, "The AppKit surface must contain the table outside the prose column")
        }
    }

    @Test func hitTestingReachesBothSidesOutsideReadingColumn() throws {
        let h = try Harness()
        let box = try h.box()
        for x in [box.box.minX + 4, box.box.maxX - 4] {
            let hit = try #require(h.view.wideTableBox(at: CGPoint(x: x, y: box.scrollerStrip.midY)))
            #expect(hit.sourceID == box.sourceID)
        }
        #expect(h.view.wideTableBox(at: CGPoint(x: box.box.minX - 2, y: box.box.midY)) == nil)
    }

    @Test func windowResizeKeepsProseWidthAndUpdatesTableClipWithoutChangingSource() throws {
        let h = try Harness()
        let before = try h.box()
        h.view.tableHorizontalScrollOffsets[before.sourceID] = 80
        let selection = h.view.selectedRange()
        h.stack.scrollView.setFrameSize(NSSize(width: 700, height: 900))
        h.view.centerReadingColumn(forClipWidth: 700)
        h.restyle()
        let after = try h.box()
        #expect(h.view.textContainer?.size.width == 400)
        #expect(h.view.textContainerOrigin.x == 150)
        #expect(abs(after.box.width - 636) < 1)
        #expect(abs(after.box.minX - 32) < 1)
        #expect(after.sourceID == before.sourceID)
        #expect(h.view.tableHorizontalScrollOffsets[after.sourceID] == 80)
        #expect(h.view.string == h.source)
        #expect(h.view.selectedRange() == selection)
    }

    @Test func extraGutterLeavesRoomForLineNumbers() throws {
        let h = try Harness(gutter: 68)
        let box = try h.box()
        #expect(abs(box.box.minX - 68) < 1)
        #expect(abs(box.box.maxX - 932) < 1)
        #expect(h.view.textContainer?.size.width == 400)
    }

    @Test func narrowTableStaysAtProseLeadingEdge() throws {
        let h = try Harness(source: "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nTail.")
        let fragment = try h.tableFragment()
        #expect(fragment.scrollableBlockBoxes(at: .zero).isEmpty)
        #expect(fragment.renderingSurfaceBounds.minX >= -1)
        #expect(h.view.textContainerOrigin.x == 300)
    }

    @Test func optOutKeepsExistingColumnGeometry() throws {
        let h = try Harness(enabled: false)
        let box = try h.box()
        #expect(h.view.frame.width == 464)
        #expect(h.view.frame.minX == 268)
        #expect(abs(box.box.width - 400) < 1)
    }

    @Test func fragmentActuallyDrawsInBothOuterMargins() throws {
        let h = try Harness()
        let fragment = try h.tableFragment()
        let box = try h.box()
        let origin = fragment.layoutFragmentFrame.origin
        let drawOrigin = CGPoint(x: origin.x + h.view.textContainerOrigin.x,
                                 y: origin.y + h.view.textContainerOrigin.y)
        let image = MarkdownStyler.bitmapImage(size: NSSize(width: 1000, height: box.box.maxY + 10),
                                               appearance: NSAppearance(named: .aqua)!) {
            fragment.draw(at: drawOrigin, in: NSGraphicsContext.current!.cgContext)
        }
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width
        for strip in [CGRect(x: 40, y: box.box.minY, width: 240, height: box.box.height),
                      CGRect(x: 720, y: box.box.minY, width: 240, height: box.box.height)] {
            var ink = 0
            for y in Int(strip.minY * scale)..<Int(strip.maxY * scale) {
                for x in Int(strip.minX * scale)..<Int(strip.maxX * scale) {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
                }
            }
            #expect(ink > 100, "The fragment must paint table text and rules outside the reading column")
        }
    }
}
