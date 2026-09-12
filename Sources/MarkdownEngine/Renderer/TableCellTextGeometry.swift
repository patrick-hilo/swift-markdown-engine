import AppKit

/// AppKit text geometry using the same alignment and wrapping as table drawing.
final class TableCellTextGeometry {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer

    init(_ text: NSAttributedString, size: CGSize, alignment: MarkdownStyler.TableAlignment) {
        storage = NSTextStorage(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        container = NSTextContainer(size: size)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
    }

    func insertionIndex(at point: CGPoint) -> Int {
        var fraction: CGFloat = 0
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return min(index + (fraction >= 0.5 ? 1 : 0), storage.length)
    }

    func rect(for range: NSRange) -> CGRect {
        manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
    }
}
