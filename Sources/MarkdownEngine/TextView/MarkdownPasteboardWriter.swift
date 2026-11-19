//
//  MarkdownPasteboardWriter.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//
//  Writes a clean, multi-flavor representation of a raw markdown selection to
//  an NSPasteboard. The editor's storage holds RAW markdown styled in place,
//  so a default copy leaks syntax markers and drops thematic breaks. Here we
//  render the raw markdown to clean HTML, write it as web archive + HTML,
//  derive RTF with visible stand-ins for constructs RTF cannot carry, and
//  keep the raw markdown itself as the plain-text flavor.
//

import AppKit

enum MarkdownPasteboardWriter {
    /// Private flavor carrying the exact raw markdown of the selection. When one
    /// of our own editors pastes, it prefers this over the derived HTML so wiki
    /// links (`[[Name|UUID]]`), code, and every other construct round-trip
    /// byte-exact instead of being re-derived from the lossy HTML flavor.
    static let markdownType = NSPasteboard.PasteboardType("dev.markdownengine.raw-markdown")

    @MainActor
    static func write(markdown: String, to pasteboard: NSPasteboard,
                      extensions: [any MarkdownExtension] = [],
                      directives: [any MarkdownDirective] = [],
                      directiveSettings: DirectiveRegistrySettings = .default) {
        write(plain: markdown, markdown: markdown, rich: markdown, to: pasteboard, extensions: extensions,
              directives: directives, directiveSettings: directiveSettings)
    }

    /// Writes the selected part of `source`, treating fenced code as code:
    /// see ``copiedText(_:in:registry:)``. The private flavor keeps the exact
    /// selection so a paste into one of our editors round-trips it.
    @MainActor
    static func write(selection: NSRange, of source: String, to pasteboard: NSPasteboard,
                      extensions: [any MarkdownExtension] = [],
                      directives: [any MarkdownDirective] = [],
                      directiveSettings: DirectiveRegistrySettings = .default,
                      registry: ExtensionRegistry = .empty) {
        let raw = (source as NSString).substring(with: selection)
        let copied = copiedText(selection, in: source, registry: registry)
        write(plain: copied.plain, markdown: raw, rich: copied.rich, to: pasteboard, extensions: extensions,
              directives: directives, directiveSettings: directiveSettings)
    }

    @MainActor
    private static func write(plain: String, markdown: String, rich: String, to pasteboard: NSPasteboard,
                              extensions: [any MarkdownExtension],
                              directives: [any MarkdownDirective],
                              directiveSettings: DirectiveRegistrySettings) {
        pasteboard.clearContents()

        pasteboard.setString(plain, forType: .string)

        // Also keep the exact raw markdown under our private flavor so our own
        // paste path can round-trip it losslessly.
        pasteboard.setString(markdown, forType: Self.markdownType)

        // Render the selection to clean HTML.
        let htmlBody = MarkdownHTMLRenderer.html(from: rich, extensions: extensions,
                                                 directives: directives, directiveSettings: directiveSettings)
        // Rich targets (web archive + RTF) show task items as plain bullets
        // (user's call); the .html flavor keeps the GFM checkbox markup so
        // markdown apps (Obsidian etc.) restore `- [ ]` on paste.
        let richBody = stripTaskCheckboxes(htmlBody)
        let fullHTML = "<html><head><meta charset=\"utf-8\"></head><body>\(htmlBody)</body></html>"
        let richHTML = "<html><head><meta charset=\"utf-8\"></head><body>\(richBody)</body></html>"

        // Web archive built straight from OUR html — deriving it from
        // NSAttributedString(html:) silently dropped <hr>, so WebKit-reading
        // consumers get the real document instead.
        if let web = webArchiveData(html: richHTML) {
            pasteboard.setData(web, forType: NSPasteboard.PasteboardType("com.apple.webarchive"))
        }
        pasteboard.setData(Data(fullHTML.utf8), forType: .html)

        // RTF for consumers without web-archive support. RTF has no horizontal
        // rule and the HTML importer drops it, so convert a body with a
        // visible ─ stand-in on the main thread.
        let rtfHTML = "<html><head><meta charset=\"utf-8\"></head><body>\(rtfFallbackBody(richBody))</body></html>"
        if let data = rtfHTML.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ),
           let rtf = try? attr.data(
               from: NSRange(location: 0, length: attr.length),
               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
           ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    /// Plain text and the markdown the rich flavors render for a selection.
    struct CopiedText: Equatable {
        let plain: String
        let rich: String
    }

    /// Code lines carry no markdown of their own. A selection inside one
    /// fenced block copies just its code as plain text: the fence lines are
    /// hidden while the caret is outside the block, so a drag over the visible
    /// block picks them up without the reader seeing them. Rich flavors get
    /// the fences back wherever the selection starts or ends inside a block;
    /// rendered without them, `# comment` became a heading and the lines ran
    /// together into one paragraph.
    static func copiedText(_ selection: NSRange, in source: String,
                           registry: ExtensionRegistry = .empty) -> CopiedText {
        let ns = source as NSString
        let raw = ns.substring(with: selection)
        let blocks = MarkdownTokenizer.parseTokensViaAST(in: source, registry: registry)
            .filter { $0.kind == .codeBlock && NSIntersectionRange($0.range, selection).length > 0 }
        guard !blocks.isEmpty else { return CopiedText(plain: raw, rich: raw) }

        let start = selection.location
        let end = NSMaxRange(selection)
        func fences(of block: MarkdownToken) -> (open: String, close: String) {
            let content = block.contentRange
            let open = ns.substring(with: NSRange(location: block.range.location,
                                                  length: content.location - block.range.location))
            var close = ns.substring(with: NSRange(location: NSMaxRange(content),
                                                   length: NSMaxRange(block.range) - NSMaxRange(content)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if close.isEmpty {
                close = String(open.trimmingCharacters(in: .whitespaces)
                    .prefix { $0 == "`" || $0 == "~" })
            }
            return (open.hasSuffix("\n") ? open : open + "\n", close)
        }
        func ensuringNewline(_ text: String) -> String {
            text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        }

        if blocks.count == 1, let block = blocks.first,
           start >= block.range.location, end <= NSMaxRange(block.range) {
            let content = block.contentRange
            let picked = NSIntersectionRange(selection, content)
            guard picked.length > 0 else { return CopiedText(plain: raw, rich: raw) }
            var plain = ns.substring(with: picked)
            if end > NSMaxRange(content), plain.hasSuffix("\n") { plain.removeLast() }
            let fence = fences(of: block)
            return CopiedText(plain: plain, rich: fence.open + ensuringNewline(plain) + fence.close)
        }

        var rich = raw
        if let first = blocks.first, start >= first.contentRange.location, start <= NSMaxRange(first.contentRange) {
            rich = fences(of: first).open + rich
        }
        if let last = blocks.last, end >= last.contentRange.location, end <= NSMaxRange(last.contentRange) {
            rich = ensuringNewline(rich) + fences(of: last).close
        }
        return CopiedText(plain: raw, rich: rich)
    }

    /// Stand-in for what RTF can't carry: the Cocoa HTML importer drops `<hr>`,
    /// so substitute a line of U+2500 (glyphs connect edge-to-edge); 40 chars
    /// reads full-width yet never wraps in ~72-char columns.
    static func rtfFallbackBody(_ body: String) -> String {
        body.replacingOccurrences(of: "<hr>", with: "<p>\(rtfRuleStandIn)</p>")
    }

    /// The visible horizontal-rule stand-in for the RTF flavor.
    static let rtfRuleStandIn = String(repeating: "─", count: 40)

    /// Rich targets show task items as plain bullets: drop the GFM checkbox
    /// inputs the renderer emits (the .html flavor keeps them).
    static func stripTaskCheckboxes(_ body: String) -> String {
        body
            .replacingOccurrences(of: "<input type=\"checkbox\" checked disabled> ", with: "")
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled> ", with: "")
    }

    /// A minimal Safari-style web archive with `html` as its main resource.
    static func webArchiveData(html: String) -> Data? {
        let resource: [String: Any] = [
            "WebResourceData": Data(html.utf8),
            "WebResourceMIMEType": "text/html",
            "WebResourceTextEncodingName": "UTF-8",
            "WebResourceURL": "about:blank",
        ]
        return try? PropertyListSerialization.data(
            fromPropertyList: ["WebMainResource": resource],
            format: .binary,
            options: 0
        )
    }
}
