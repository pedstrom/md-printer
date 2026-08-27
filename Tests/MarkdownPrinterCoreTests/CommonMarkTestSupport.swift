import Foundation
@testable import MarkdownPrinterCore

struct CommonMarkFixture: Decodable {
    let commonmarkVersion: String
    let examples: [CommonMarkExample]
}

struct CommonMarkExample: Decodable {
    let markdown: String
    let html: String
    let example: Int
    let section: String
}

enum CommonMarkHTMLSerializer {
    static func serialize(_ blocks: [MarkdownBlock]) -> String {
        blocks.map(serialize).joined()
    }

    private static func serialize(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(level, content):
            return "<h\(level)>\(inline(content))</h\(level)>\n"
        case let .paragraph(content):
            return "<p>\(inline(content))</p>\n"
        case let .blockquote(blocks):
            return "<blockquote>\n\(serialize(blocks))</blockquote>\n"
        case let .list(items, ordered, start, tight):
            let opening: String
            if ordered {
                opening = start == 1 ? "<ol>\n" : "<ol start=\"\(start)\">\n"
            } else {
                opening = "<ul>\n"
            }
            return opening + items.map { serializeListItem($0, tight: tight) }.joined()
                + (ordered ? "</ol>\n" : "</ul>\n")
        case let .codeBlock(language, code):
            let classAttribute = language.map {
                " class=\"language-\(escapeAttribute($0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""))\""
            } ?? ""
            let newline = code.isEmpty || code.hasSuffix("\n") ? "" : "\n"
            return "<pre><code\(classAttribute)>\(escapeText(code))\(newline)</code></pre>\n"
        case let .rawHTML(source):
            return source
        case .thematicBreak:
            return "<hr />\n"
        case .footnoteDefinition:
            return ""
        case let .table(headers, _, rows):
            let header = "<thead>\n<tr>\n" + headers.map { "<th>\(inline($0))</th>\n" }.joined() + "</tr>\n</thead>\n"
            let body = "<tbody>\n" + rows.map { row in
                "<tr>\n" + row.map { "<td>\(inline($0))</td>\n" }.joined() + "</tr>\n"
            }.joined() + "</tbody>\n"
            return "<table>\n\(header)\(body)</table>\n"
        }
    }

    private static func serializeListItem(_ item: MarkdownListItem, tight: Bool) -> String {
        guard !item.blocks.isEmpty else { return "<li></li>\n" }
        guard tight else { return "<li>\n\(serialize(item.blocks))</li>\n" }

        var result = "<li>"
        for (index, block) in item.blocks.enumerated() {
            if case let .paragraph(content) = block {
                result += inline(content)
            } else {
                if index == 0 || !result.hasSuffix("\n") { result += "\n" }
                result += serialize(block)
            }
        }
        return result + "</li>\n"
    }

    private static func inline(_ nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case let .text(value): return escapeText(value)
            case let .emphasis(children): return "<em>\(inline(children))</em>"
            case let .strong(children): return "<strong>\(inline(children))</strong>"
            case let .underline(children): return "<u>\(inline(children))</u>"
            case let .strikethrough(children): return "<del>\(inline(children))</del>"
            case let .code(value): return "<code>\(escapeText(value))</code>"
            case let .link(children, destination, title):
                let titleAttribute = title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
                return "<a href=\"\(escapeAttribute(percentEncode(destination)))\"\(titleAttribute)>\(inline(children))</a>"
            case let .footnoteReference(label): return "[^\(escapeText(label))]"
            case let .image(alt, source, title):
                let titleAttribute = title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
                return "<img src=\"\(escapeAttribute(percentEncode(source)))\" alt=\"\(escapeAttribute(alt))\"\(titleAttribute) />"
            case let .rawHTML(source): return source
            case .softBreak: return "\n"
            case .hardBreak: return "<br />\n"
            }
        }.joined()
    }

    private static func escapeText(_ source: String) -> String {
        source.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttribute(_ source: String) -> String {
        escapeText(source)
    }

    private static func percentEncode(_ source: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789;/?:@&=+$,-_.!~*'()#%".utf8)
        return source.utf8.map { byte in
            allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}

func normalizedCommonMarkHTML(_ html: String) -> String {
    html.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}
