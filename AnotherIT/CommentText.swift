import SwiftUI

/// A block of a comment body. Comments are stored as lightweight Markdown:
/// quotes (`> `), lists, code fences, headings and inline formatting.
enum MessageBlock: Hashable {
    case paragraph(AttributedString)
    case quote(AttributedString)
    case listItem(marker: String, text: AttributedString)
    case heading(AttributedString)
    case code(String)
}

enum CommentMarkdown {
    static let commentScheme = "anotherit-comment"

    static func blocks(from text: String) -> [MessageBlock] {
        var result: [MessageBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var listItem: (marker: String, lines: [String])?
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
                paragraph.removeAll()
            }
            if !quote.isEmpty {
                result.append(.quote(inline(quote.joined(separator: "\n"))))
                quote.removeAll()
            }
            if let item = listItem {
                result.append(.listItem(marker: item.marker, text: inline(item.lines.joined(separator: "\n"))))
                listItem = nil
            }
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if code != nil {
                if trimmed.hasPrefix("```") {
                    result.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                var body = trimmed.dropFirst()
                if body.hasPrefix(" ") { body = body.dropFirst() }
                quote.append(String(body))
                continue
            }
            if let item = parseListItem(trimmed) {
                flush()
                listItem = (item.marker, [item.body])
                continue
            }
            if trimmed.hasPrefix("#") {
                let body = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty {
                    flush()
                    result.append(.heading(inline(body)))
                    continue
                }
            }
            if listItem != nil {
                listItem!.lines.append(trimmed)
                continue
            }
            if !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let code {
            result.append(.code(code.joined(separator: "\n")))
        }
        flush()
        return result
    }

    private static func parseListItem(_ line: String) -> (marker: String, body: String)? {
        if let first = line.first, "-*+•".contains(first) {
            let rest = line.dropFirst()
            if rest.first == " " {
                return ("•", rest.trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let sep = rest.first, sep == "." || sep == ")", rest.dropFirst().first == " " else { return nil }
        return ("\(digits).", rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let replyRef = try? NSRegularExpression(pattern: "@(\\d{2,})")

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)

        let plain = String(attr.characters)
        let fullRange = NSRange(plain.startIndex..., in: plain)

        linkDetector?.enumerateMatches(in: plain, range: fullRange) { match, _, _ in
            guard let match, let url = match.url,
                  let range = Range(match.range, in: attr),
                  attr[range].link == nil else { return }
            attr[range].link = url
        }
        replyRef?.enumerateMatches(in: plain, range: fullRange) { match, _, _ in
            guard let match,
                  let idRange = Range(match.range(at: 1), in: plain),
                  let range = Range(match.range, in: attr),
                  attr[range].link == nil,
                  let url = URL(string: "\(commentScheme)://\(plain[idRange])") else { return }
            attr[range].link = url
        }
        return attr
    }
}

struct MessageView: View {
    let blocks: [MessageBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(text)
                case .heading(let text):
                    Text(text).font(.headline)
                case .quote(let text):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 3)
                        Text(text)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .listItem(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(text)
                    }
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(8)
                    }
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}
