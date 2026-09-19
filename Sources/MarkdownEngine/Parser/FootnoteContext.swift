import Foundation

/// Conservative source regions in which a bracket-caret sequence is literal.
enum FootnoteContext {
    private static let listPrefix = try! NSRegularExpression(pattern: #"^(?:[-+*] |[0-9]+[.)] )"#)
    private static let blockHTML = try! NSRegularExpression(pattern: #"^</?(?:address|article|aside|base|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|pre|script|search|section|style|summary|table|tbody|td|textarea|tfoot|th|thead|title|tr|track|ul)(?:[\s/>]|$)"#, options: .caseInsensitive)
    private static let inlineProtected = [
        #"<!--(?s:.*?)(?:-->|$)"#,
        #"<[^>\n]*(?:>|$)"#,
        #"!?\[(?:[^\[\]\n]|\[[^\[\]\n]*\])*\]\([^\n]*?\)"#
    ].map { try! NSRegularExpression(pattern: $0) }

    static func protectionChanged(old: [NSRange], new: [NSRange], diff: BufferDiff) -> Bool {
        let previous = old.map { range -> NSRange in
            func shifted(_ position: Int) -> Int {
                if position <= diff.changeStart { return position }
                if position >= diff.changeEndOld { return position + diff.delta }
                return diff.changeEndNew
            }
            let start = shifted(range.location)
            return NSRange(location: start, length: max(0, shifted(NSMaxRange(range)) - start))
        }
        return previous != new
    }

    static func protectedRanges(in source: NSString) -> [NSRange] {
        guard source.range(of: "[^", options: .literal).location != NSNotFound else { return [] }
        var ranges: [NSRange] = []
        var offset = 0
        var frontmatter = false
        var htmlBlock = false
        var definition = false
        var fence: Character?
        var fenceLength = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var content = trimmed
            while content.hasPrefix(">") { content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let listPrefix = Self.listPrefix.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length))
            if let listPrefix { content = (content as NSString).substring(from: NSMaxRange(listPrefix.range)) }
            let indentedCode = listPrefix == nil && (line.hasPrefix("    ") || line.hasPrefix("\t"))
            if let activeFence = fence {
                ranges.append(range)
                let closingRun = content.prefix(while: { $0 == activeFence }).count
                if closingRun >= fenceLength, content.dropFirst(closingRun).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                offset = NSMaxRange(range)
                continue
            }
            if !frontmatter, let marker = content.first, marker == "`" || marker == "~" || marker == "$" {
                let count = content.prefix(while: { $0 == marker }).count
                if count >= (marker == "$" ? 2 : 3), marker != "`" || !content.dropFirst(count).contains("`") {
                    fence = marker
                    fenceLength = count
                    ranges.append(range)
                    offset = NSMaxRange(range)
                    continue
                }
            }
            if offset == 0, line == "---" { frontmatter = true }
            if frontmatter {
                ranges.append(range)
                if offset > 0, line == "---" || line == "..." { frontmatter = false }
            } else {
                if Self.blockHTML.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) != nil { htmlBlock = true }
                if trimmed.isEmpty { htmlBlock = false }
                if content.hasPrefix("["), content.contains("]:") { definition = true }
                else if !trimmed.isEmpty, !line.hasPrefix("    "), !line.hasPrefix("\t") { definition = false }
                if htmlBlock || definition || indentedCode {
                    ranges.append(range)
                }
            }
            offset = NSMaxRange(range)
        }
        for regex in inlineProtected {
            ranges += regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map(\.range)
        }
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        return merged
    }
}
