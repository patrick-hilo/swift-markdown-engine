//
//  TestBitmaps.swift
//  MarkdownEngineTests
//
//  Rasterization helpers for tests that compare drawn tables pixel by pixel.
//  Production no longer rasterizes tables; this is the former engine helper,
//  kept verbatim so the pixel oracles keep their format.
//

import AppKit
@testable import MarkdownEngine

extension MarkdownStyler {

    /// Backing scale the test bitmaps are rasterized at: the largest attached
    /// screen, so pixel probes agree with what the display would show.
    static var tableBitmapScale: CGFloat {
        let largest = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return max(1, largest)
    }

    /// Rasterizes `draw` into an 8-bit RGBA `CGImage` at `tableBitmapScale` and
    /// wraps it in an `NSImage` of `size` points.
    ///
    /// A drawing-handler `NSImage` would let AppKit snapshot the table into a
    /// bitmap in the window's own format — on wide-gamut displays that is 16-bit
    /// float, 8 bytes per pixel. Tables are anti-aliased text and a few flat
    /// colors; 8 bits per channel is enough and halves the memory. The bitmap is
    /// CG-owned (not an `NSBitmapImageRep` buffer) so the wide-table overlays'
    /// layers can share it with the render server instead of copying it. The
    /// context is flipped so the top-down cell offsets draw directly and text
    /// stays upright. `appearance` resolves the dynamic colors while drawing.
    static func bitmapImage(size: NSSize, appearance: NSAppearance, draw: () -> Void) -> NSImage {
        let scale = tableBitmapScale
        let pixelsWide = max(1, Int((size.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((size.height * scale).rounded(.up)))
        let image = NSImage(size: size)
        guard let cgContext = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return image
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)
        cgContext.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cgContext.scaleBy(x: scale, y: -scale)
        // The bitmap is rendered ahead of display, so dynamic colors (text, code
        // background) must resolve under the text view's appearance here, not
        // under whatever is current when the image is later drawn.
        appearance.performAsCurrentDrawingAppearance { draw() }
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = cgContext.makeImage() else { return image }
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage).withSize(size))
        return image
    }
}

private extension NSBitmapImageRep {
    func withSize(_ size: NSSize) -> NSBitmapImageRep {
        self.size = size
        return self
    }
}
