import AppKit
import Testing
@testable import MarkdownEngine

/// A fenced block whose language a `DiagramRenderer` handles shows the
/// rendered diagram while the caret is elsewhere and its source while the
/// caret is inside — the block-LaTeX collapse, applied to code fences.
@Suite("Diagram code blocks")
struct DiagramBlockStylingTests {
    final class StubRenderer: DiagramRenderer, @unchecked Sendable {
        var image: NSImage?
        var requests: [DiagramRequest] = []
        func handles(language: String) -> Bool { language == "mermaid" }
        func diagram(for request: DiagramRequest) -> DiagramRenderResult? {
            requests.append(request)
            return image.map { DiagramRenderResult(image: $0, size: $0.size) }
        }
        var didRenderNotification: Notification.Name? { nil }
    }

    static let source = "Intro\n\n```mermaid\ngraph LR\n  A --> B\n```\n\nTail\n"

    static func style(_ text: String, renderer: StubRenderer, active: Bool) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.diagrams = renderer
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let codeIndex = tokens.firstIndex { $0.kind == .codeBlock }!
        let caret = active ? tokens[codeIndex].contentRange.location : 0
        return MarkdownStyler.styleAttributes(
            text: text, fontName: "Helvetica", fontSize: 15,
            caretLocation: caret, activeTokenIndices: active ? [codeIndex] : [],
            precomputedTokens: tokens, configuration: configuration
        )
    }

    static func imageAnchors(_ attrs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])]) -> [NSRange] {
        attrs.filter { $0.attributes[.latexImage] is NSImage }.map(\.range)
    }

    @Test func inactiveBlockCollapsesToTheRenderedImage() throws {
        let renderer = StubRenderer()
        renderer.image = NSImage(size: NSSize(width: 120, height: 60))
        let attrs = Self.style(Self.source, renderer: renderer, active: false)
        let anchors = Self.imageAnchors(attrs)
        #expect(anchors.count == 1)
        let content = (Self.source as NSString).range(of: "graph LR")
        #expect(anchors.first?.location == content.location)
        #expect(renderer.requests == [DiagramRequest(language: "mermaid", source: "graph LR\n  A --> B\n")])
        let bounds = try #require(attrs.first { $0.attributes[.latexImage] != nil }?.attributes[.latexBounds] as? NSValue)
        #expect(bounds.rectValue.size == CGSize(width: 120, height: 60))
    }

    @Test func activeBlockShowsItsSourceAndAsksNothing() {
        let renderer = StubRenderer()
        renderer.image = NSImage(size: NSSize(width: 120, height: 60))
        let attrs = Self.style(Self.source, renderer: renderer, active: true)
        #expect(Self.imageAnchors(attrs).isEmpty)
        #expect(renderer.requests.isEmpty)
    }

    @Test func blockWithoutARenderedImageStaysACodeBlock() {
        let renderer = StubRenderer()
        let attrs = Self.style(Self.source, renderer: renderer, active: false)
        #expect(Self.imageAnchors(attrs).isEmpty)
        #expect(renderer.requests.count == 1)
    }

    @Test func otherLanguagesAreNeverSentToTheRenderer() {
        let renderer = StubRenderer()
        renderer.image = NSImage(size: NSSize(width: 120, height: 60))
        let text = "```swift\nlet a = 1\n```\n"
        let attrs = Self.style(text, renderer: renderer, active: false)
        #expect(Self.imageAnchors(attrs).isEmpty)
        #expect(renderer.requests.isEmpty)
    }

    @Test func wideDiagramScalesDownToTheFallbackWidthButNeverUp() throws {
        let renderer = StubRenderer()
        renderer.image = NSImage(size: NSSize(width: 4000, height: 400))
        let attrs = Self.style(Self.source, renderer: renderer, active: false)
        let bounds = try #require(attrs.first { $0.attributes[.latexImage] != nil }?.attributes[.latexBounds] as? NSValue)
        let maxWidth = MarkdownEditorConfiguration.default.imageEmbed.fallbackMaxWidth
        #expect(abs(bounds.rectValue.width - maxWidth) < 0.5)
        #expect(abs(bounds.rectValue.height - 400 * maxWidth / 4000) < 0.5)
    }

    @Test func collapsedBlockDropsTheCodeBackground() {
        let renderer = StubRenderer()
        renderer.image = NSImage(size: NSSize(width: 120, height: 60))
        let attrs = Self.style(Self.source, renderer: renderer, active: false)
        let block = (Self.source as NSString).range(of: "```mermaid\ngraph LR\n  A --> B\n```")
        let clears = attrs.filter {
            NSIntersectionRange($0.range, block).length > 0 && ($0.attributes[.backgroundColor] as? NSColor) == NSColor.clear
        }
        #expect(!clears.isEmpty)
    }

    final class NotifyingRenderer: DiagramRenderer, @unchecked Sendable {
        let name = Notification.Name("DiagramBlockStylingTests.didRender.\(UUID().uuidString)")
        var image: NSImage?
        func handles(language: String) -> Bool { language == "mermaid" }
        func diagram(for request: DiagramRequest) -> DiagramRenderResult? {
            image.map { DiagramRenderResult(image: $0, size: $0.size) }
        }
        var didRenderNotification: Notification.Name? { name }
    }

    @Test @MainActor func finishedRenderReplacesTheCodeBlockInTheEditor() throws {
        _ = NSApplication.shared
        let renderer = NotifyingRenderer()
        let text = Self.source
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "Helvetica", fontSize: 15,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.services.diagrams = renderer
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let storage = try #require(tv.textStorage)
        func hasImage() -> Bool {
            var found = false
            storage.enumerateAttribute(.latexImage, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if value is NSImage { found = true; stop.pointee = true }
            }
            return found
        }
        #expect(!hasImage())
        renderer.image = NSImage(size: NSSize(width: 120, height: 60))
        NotificationCenter.default.post(name: renderer.name, object: nil)
        #expect(hasImage())
    }
}
