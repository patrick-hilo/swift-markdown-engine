import Foundation

/// Conservative source regions in which a bracket-caret sequence is literal.
enum FootnoteContext {
    static func protectionChanged(old: NSString, new: NSString, diff: BufferDiff) -> Bool {
        let previous = protectedRanges(in: old).map { range -> NSRange in
            func shifted(_ position: Int) -> Int {
                if position <= diff.changeStart { return position }
                if position >= diff.changeEndOld { return position + diff.delta }
                return diff.changeEndNew
            }
            let start = shifted(range.location)
            return NSRange(location: start, length: max(0, shifted(NSMaxRange(range)) - start))
        }
        return previous != protectedRanges(in: new)
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
            let listPrefix = content.range(of: #"^(?:[-+*] |[0-9]+[.)] )"#, options: .regularExpression)
            if let listPrefix { content.removeSubrange(listPrefix) }
            let indentedCode = listPrefix == nil && (line.hasPrefix("    ") || line.hasPrefix("\t"))
            if let activeFence = fence {
                ranges.append(range)
                if content.prefix(while: { $0 == activeFence }).count >= fenceLength {
                    fence = nil
                }
                offset = NSMaxRange(range)
                continue
            }
            if !frontmatter, let marker = content.first, marker == "`" || marker == "~" || marker == "$" {
                let count = content.prefix(while: { $0 == marker }).count
                if count >= (marker == "$" ? 2 : 3) {
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
                if content.hasPrefix("<") { htmlBlock = true }
                if trimmed.isEmpty { htmlBlock = false }
                if content.hasPrefix("["), content.contains("]:") { definition = true }
                else if !trimmed.isEmpty, !line.hasPrefix("    "), !line.hasPrefix("\t") { definition = false }
                if htmlBlock || definition || indentedCode {
                    ranges.append(range)
                }
            }
            offset = NSMaxRange(range)
        }
        // Raw tags/comments remain opaque to footnotes.
        for pattern in ["<!--(?s:.*?)(?:-->|$)", "<[^>\\n]*(?:>|$)", #"!?\[(?:[^\[\]\n]|\[[^\[\]\n]*\])*\]\([^\n]*?\)"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                ranges += regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map(\.range)
            }
        }
        return ranges
    }
}
