import Foundation

/// Conservative source regions in which a bracket-caret sequence is literal.
enum FootnoteContext {
    static func protectedRanges(in source: NSString) -> [NSRange] {
        guard source.range(of: "[^", options: .literal).location != NSNotFound else { return [] }
        var ranges: [NSRange] = []
        var offset = 0
        var frontmatter = false
        var htmlBlock = false
        var definition = false
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if offset == 0, line == "---" { frontmatter = true }
            if frontmatter {
                ranges.append(range)
                if offset > 0, line == "---" || line == "..." { frontmatter = false }
            } else {
                if trimmed.hasPrefix("<") { htmlBlock = true }
                if trimmed.isEmpty { htmlBlock = false }
                if trimmed.hasPrefix("[^"), trimmed.contains("]:") { definition = true }
                else if !trimmed.isEmpty, !line.hasPrefix("    "), !line.hasPrefix("\t") { definition = false }
                if htmlBlock || definition || line.hasPrefix("    ") || line.hasPrefix("\t") {
                    ranges.append(range)
                }
            }
            offset = NSMaxRange(range)
        }
        // Raw tags/comments remain opaque to footnotes.
        for pattern in ["<!--(?s:.*?)-->", "<[^>]*>"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                ranges += regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map(\.range)
            }
        }
        return ranges
    }
}
