import AppKit

extension NSAttributedString.Key {
    static let tableCellInputRange = NSAttributedString.Key("TableCellInputRange")
}

/// UTF-16 correspondence from the formatted cell back to its untouched Markdown.
struct TableCellProjection {
    let text: String
    let sourceUnits: [NSRange]

    init(source: TableCellSource, formatted: NSAttributedString) {
        let raw = source.text as NSString
        var units: [NSRange] = []
        var chars: [unichar] = []
        var i = 0
        while i < raw.length {
            if raw.character(at: i) == 92, i + 1 < raw.length {
                if raw.character(at: i + 1) == 124 {
                    chars.append(124); units.append(NSRange(location: i, length: 2)); i += 2; continue
                }
                for j in i...i + 1 { chars.append(raw.character(at: j)); units.append(NSRange(location: j, length: 1)) }
                i += 2; continue
            }
            chars.append(raw.character(at: i)); units.append(NSRange(location: i, length: 1)); i += 1
        }
        let unescaped = String(utf16CodeUnits: chars, count: chars.count) as NSString
        let regex = try! NSRegularExpression(pattern: "<br\\s*/?>", options: [.caseInsensitive])
        for match in regex.matches(in: unescaped as String, range: NSRange(location: 0, length: unescaped.length)).reversed() {
            let first = units[match.range.location], last = units[NSMaxRange(match.range) - 1]
            units.replaceSubrange(match.range.location..<NSMaxRange(match.range), with: [NSRange(location: first.location, length: NSMaxRange(last) - first.location)])
        }
        var mapped = Array(repeating: NSRange(location: source.range.location, length: 0), count: formatted.length)
        formatted.enumerateAttribute(.tableCellInputRange, in: NSRange(location: 0, length: formatted.length)) { value, output, _ in
            guard let input = (value as? NSValue)?.rangeValue, NSMaxRange(input) <= units.count, input.length > 0 else { return }
            for index in 0..<output.length {
                let a = units[input.location + (input.length == output.length ? index : 0)]
                let b = units[input.length == output.length ? input.location + index : NSMaxRange(input) - 1]
                mapped[output.location + index] = NSRange(location: source.range.location + a.location, length: NSMaxRange(b) - a.location)
            }
        }
        text = formatted.string
        sourceUnits = mapped
    }

    func sourceRange(for range: NSRange) -> NSRange? {
        guard range.length > 0, NSMaxRange(range) <= sourceUnits.count else { return nil }
        let first = sourceUnits[range.location], last = sourceUnits[NSMaxRange(range) - 1]
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    func displayRanges(for source: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        for (i, unit) in sourceUnits.enumerated() where NSIntersectionRange(unit, source).length > 0 {
            if let last = ranges.last, NSMaxRange(last) == i { ranges[ranges.count - 1].length += 1 }
            else { ranges.append(NSRange(location: i, length: 1)) }
        }
        return ranges
    }
}
