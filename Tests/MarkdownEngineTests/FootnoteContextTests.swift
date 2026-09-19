import AppKit
import Testing
@testable import MarkdownEngine

private struct Footnote: MarkdownExtension {
    let id = "test.footnote"
    let inline: InlineSyntax? = InlineSyntax(open: "[^", close: "]", parsesContent: false,
        rejectsOpenerRun: false, isFootnoteReference: true)
    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] { [.baselineOffset: 4] }
    func html(childrenHTML: String) -> String { "<sup>\(childrenHTML)</sup>" }
}

struct FootnoteContextTests {
    @Test func referencesAndProtectedContexts() {
        let source = """
        ---
        title: "[^yaml]"
        ---

        Prose [^a] and **bold [^b]**, `[^code]`, \\[^escaped].
        [label [^link]](target) ![alt [^image]](image.png)
        Text <span title="[^attribute]">text</span> <!-- [^comment] -->.

        [^a]: Definition [^inside]
            continuation [^continuation]

            [^indented]

        ```
        [^fenced]
        ```

        <div>
        [^html]
        </div>

        - Item [^list]
            - Nested [^nested]
        > Quote [^quote]

        End [^last]. [^bad label] [^] [^unclosed
        """
        let registry = ExtensionRegistry(extensions: [Footnote()])
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: source, registry: registry)
        let labels = tokens.filter { $0.kind == .extensionSpan("test.footnote") }
            .map { (source as NSString).substring(with: $0.contentRange) }
        #expect(labels == ["a", "b", "list", "nested", "quote", "last"])
        let html = MarkdownHTMLRenderer.html(from: source, extensions: [Footnote()])
        for label in ["a", "b", "list", "nested", "quote", "last"] { #expect(html.contains("<sup>\(label)</sup>")) }
        for label in ["yaml", "code", "escaped", "link", "image", "attribute", "comment", "inside", "continuation", "indented", "fenced", "html"] {
            #expect(!html.contains("<sup>\(label)</sup>"))
        }
    }

    @Test func contextChangesInvalidateCachedTokens() {
        let registry = ExtensionRegistry(extensions: [Footnote()])
        for source in ["---\ntitle: [^a]\n---\n", "text\ntitle: [^a]\n---\n", "---\ntitle: [^a]\n---\n"] {
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: source, registry: registry)
            #expect(tokens.contains { $0.kind == .extensionSpan("test.footnote") } == source.hasPrefix("text"))
        }
    }
}

extension FootnoteContextTests {
    @Test func otherProtectedBlocks() {
        let source = """
        [link]: path "[^title]"

        > [^quoted]: Definition [^body]

        > ```
        > [^codeInQuote]
        > ```

        ~~~
        [^tilde]
        ~~~

        $$
        [^math]
        $$

        Text <!-- unfinished [^comment]
        """
        let registry = ExtensionRegistry(extensions: [Footnote()])
        #expect(!MarkdownTokenizer.parseTokensViaAST(in: source, registry: registry).contains {
            $0.kind == .extensionSpan("test.footnote")
        })
        #expect(!MarkdownHTMLRenderer.html(from: source, extensions: [Footnote()]).contains("<sup>"))
    }

    @Test func nestedLinkAndImageLabelsRemainWholeConstructs() {
        for source in ["[a [nested] label](target)", "[a `]` label](target)", #"[a \] label](target)"#, "![a [nested] label](image.png)"] {
            let nodes = InlineParser.parse(source)
            #expect(nodes.count == 1)
            switch nodes.first {
            case .link, .image: break
            default: Issue.record("Label was split: \(source)")
            }
        }
        #expect(MarkdownHTMLRenderer.html(from: "[a [nested] label](target)").contains("href=\"target\""))
        #expect(!MarkdownHTMLRenderer.html(from: "[outer [inner](one)](two)").contains("href=\"two\""))
        let malformed = "[a [nested] label(target)"
        #expect(!InlineParser.parse(malformed).contains { if case .link = $0 { return true }; return false })
    }
}

extension FootnoteContextTests {
    @Test func inlineHTMLAndAutolinksDoNotProtectFollowingProse() {
        let source = "<https://example.com> prose[^n]\n<em>x</em> prose[^m]\n\n$$x$$\n\nProse[^mathAfter]\n"
        let html = MarkdownHTMLRenderer.html(from: source, extensions: [Footnote()])
        #expect(html.contains("<sup>n</sup>"))
        #expect(html.contains("<sup>m</sup>"))
        #expect(html.contains("<sup>mathAfter</sup>"))
    }

    @Test func fenceInfoDoesNotCloseCodeAndLinkedImagesStayLinks() {
        let source = "```\n[^a]\n```not-a-close\n[^b]\n```\n\nProse[^c]\n"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: source, registry: ExtensionRegistry(extensions: [Footnote()]))
        let references = tokens.filter { $0.kind == .extensionSpan("test.footnote") }
        #expect(references.map { (source as NSString).substring(with: $0.contentRange) } == ["c"])
        let linkedImage = "[![alt](image.png)](target)"
        guard case .link(let range, _, _, _, _) = InlineParser.parse(linkedImage).first else {
            Issue.record("Linked image lost outer link"); return
        }
        #expect(range == NSRange(location: 0, length: linkedImage.utf16.count))
        #expect(MarkdownHTMLRenderer.html(from: linkedImage).contains("href=\"target\""))
    }
}
