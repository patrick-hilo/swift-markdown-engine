import Foundation

/// A single cell's source span. Surrounding whitespace and every other cell stay untouched.
struct TableCellSource {
    let range: NSRange
    let text: String
    let prefix: String
    let suffix: String
    var requiresSpaceWhenEmpty = false

    static func cell(in source: String, row: Int, column: Int) -> TableCellSource? {
        guard row >= 0, column >= 0 else { return nil }
        let ns = source as NSString
        var lines: [NSRange] = []
        var offset = 0
        while offset < ns.length {
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            let range = NSRange(location: offset, length: contentsEnd - offset)
            if !ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty { lines.append(range) }
            offset = end
        }
        let lineIndex = row == 0 ? 0 : row + 1
        guard lines.indices.contains(lineIndex) else { return nil }
        let line = lines[lineIndex]
        let raw = ns.substring(with: line) as NSString
        let trimmed = (raw as String).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let trimRange = raw.range(of: trimmed)
        var start = line.location + trimRange.location
        let end = start + trimRange.length
        if ns.character(at: start) == 124 { start += 1 }
        var spans: [NSRange] = []
        var escaped = false
        var cellStart = start
        var trailingDelimiter = false
        for i in start..<end {
            let ch = ns.character(at: i)
            if escaped { escaped = false; continue }
            if ch == 92 { escaped = true; continue }
            if ch == 124 {
                spans.append(NSRange(location: cellStart, length: i - cellStart))
                cellStart = i + 1
                trailingDelimiter = i == end - 1
            }
        }
        if !trailingDelimiter { spans.append(NSRange(location: cellStart, length: end - cellStart)) }
        if column < spans.count {
            let span = spans[column]
            let rawCell = ns.substring(with: span) as NSString
            let content = (rawCell as String).trimmingCharacters(in: .whitespaces)
            let relative = content.isEmpty ? NSRange(location: rawCell.length, length: 0) : rawCell.range(of: content)
            return TableCellSource(range: NSRange(location: span.location + relative.location, length: relative.length),
                                   text: content, prefix: "", suffix: "",
                                   requiresSpaceWhenEmpty: spans.count == 1 && span.length == relative.length)
        }
        // GFM displays omitted trailing cells as empty. Materialize only the requested row's gap.
        let missing = column - spans.count
        let prefix = (trailingDelimiter ? " " : " | ") + String(repeating: " | ", count: missing)
        return TableCellSource(range: NSRange(location: end, length: 0), text: "", prefix: prefix,
                               suffix: trailingDelimiter ? " |" : "")
    }

    func replacement(for text: String) -> String {
        let encoded = Self.encode(text)
        return prefix + (encoded.isEmpty && requiresSpaceWhenEmpty ? " " : encoded) + suffix
    }

    static func encode(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
        var output = ""
        var escaped = false
        for character in line {
            if character == "|", !escaped { output.append("\\") }
            output.append(character)
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        if escaped { output.append("\\") }
        return output
    }
}
