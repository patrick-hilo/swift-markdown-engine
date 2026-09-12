import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Cell source splices")
struct TableCellSourceEditingTests {
    @Test func preservesOtherCellsWhitespaceAndLineEndings() throws {
        let source = "| A | B |\r\n|---|---|\r\n|  old  | untouched |\r\n"
        let cell = try #require(TableCellSource.cell(in: source, row: 1, column: 0))
        let result = (source as NSString).replacingCharacters(in: cell.range, with: cell.replacement(for: "new"))
        #expect(result == "| A | B |\r\n|---|---|\r\n|  new  | untouched |\r\n")
    }

    @Test func escapedPipesAndCodeKeepTheirCellBoundaries() throws {
        let source = "| A | B |\n|---|---|\n| `a \\| b` | c\\|d |"
        #expect(try #require(TableCellSource.cell(in: source, row: 1, column: 0)).text == "`a \\| b`")
        #expect(try #require(TableCellSource.cell(in: source, row: 1, column: 1)).text == "c\\|d")
        #expect(TableCellSource.encode("`a | b` \\| c") == "`a \\| b` \\| c")
        #expect(TableCellSource.encode("a\\\\|b") == "a\\\\\\|b")
    }

    @Test func unicodeEmptyCellsAndPastedLines() throws {
        let source = "| 😀 | é | 空 |\n|---|---|---|\n| a |   | z |"
        #expect(try #require(TableCellSource.cell(in: source, row: 0, column: 1)).text == "é")
        let cell = try #require(TableCellSource.cell(in: source, row: 1, column: 1))
        #expect(cell.range.length == 0)
        let result = (source as NSString).replacingCharacters(in: cell.range, with: cell.replacement(for: "😀\r\n空"))
        #expect(result.hasSuffix("| a |   😀<br>空| z |"))
    }

    @Test func missingTrailingCellsOnlyExtendTheirRow() throws {
        for body in ["| a |", "a"] {
            let source = "| A | B | C |\n|---|---|---|\n" + body
            let cell = try #require(TableCellSource.cell(in: source, row: 1, column: 2))
            let result = (source as NSString).replacingCharacters(in: cell.range, with: cell.replacement(for: "last"))
            let parsed = try #require(MarkdownStyler.parseTableSource(result))
            #expect(parsed.rows == [["a", "", "last"]])
        }
    }
}
