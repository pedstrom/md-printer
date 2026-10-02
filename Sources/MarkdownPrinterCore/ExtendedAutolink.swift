import Foundation

/// GFM extended autolinks. Kept independent of rendering and platform APIs.
enum ExtendedAutolink {
    private static let web = try! NSRegularExpression(pattern: "^(?:https?://|www\\.)[^\\s<]+", options: .caseInsensitive)
    private static let domain = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+")
    private static let email = try! NSRegularExpression(pattern: "^(?:(?:mailto|xmpp):)?[A-Za-z0-9._+-]+@[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+", options: .caseInsensitive)
    private static let entity = try! NSRegularExpression(pattern: "&[A-Za-z0-9]+;$")
    private static let resource = try! NSRegularExpression(pattern: "^/[A-Za-z0-9@.]+")

    static func parse(in source: String, at index: String.Index) -> (label: String, destination: String, end: String.Index)? {
        let character = source[index]
        guard character.isASCII, character.isLetter || character.isNumber || ".-_+".contains(character) else { return nil }
        let previous = index == source.startIndex ? nil : source[source.index(before: index)]
        let webBoundary = previous == nil || previous!.isWhitespace || "*_~(".contains(previous!)
        let prefix = source[index...].prefix(8).lowercased()
        let webStart = webBoundary && (prefix.hasPrefix("http://") || prefix.hasPrefix("https://") || prefix.hasPrefix("www."))
        let emailBoundary = previous == nil || !previous!.isASCII || !(previous!.isLetter || previous!.isNumber || ".-_+@".contains(previous!))
        guard webStart || emailBoundary else { return nil }
        if !webStart, !prefix.hasPrefix("mailto:"), !prefix.hasPrefix("xmpp:") {
            let local = source[index...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+".contains($0)) }
            let at = source.index(index, offsetBy: local.count)
            guard at < source.endIndex, source[at] == "@" else { return nil }
        }
        let suffix = String(source[index...])
        if webBoundary, let candidate = match(web, in: suffix) {
            var label = candidate
            while let last = label.last, "?!.,:*_~".contains(last) { label.removeLast() }
            while label.last == ")", label.filter({ $0 == ")" }).count > label.filter({ $0 == "(" }).count {
                label.removeLast()
            }
            if let range = entity.firstMatch(in: label, range: NSRange(label.startIndex..., in: label))?.range,
               let swiftRange = Range(range, in: label) { label.removeSubrange(swiftRange) }
            let isWWW = candidate.lowercased().hasPrefix("www.")
            guard label.count >= (isWWW ? 4 : (prefix.hasPrefix("https://") ? 8 : 7)) else { return nil }
            let hostStart = isWWW ? label.startIndex : label.index(label.startIndex, offsetBy: label.lowercased().hasPrefix("https://") ? 8 : 7)
            let hostAndPath = String(label[hostStart...])
            if let host = match(domain, in: hostAndPath) {
                let segments = host.split(separator: ".")
                if !segments.suffix(2).contains(where: { $0.contains("_") }) {
                    return (label, (isWWW ? "http://" : "") + CommonMarkEntityDecoder.decode(label), source.index(index, offsetBy: label.count))
                }
            }
        }
        // Starting in the middle of a local-part must not recover an invalid address.
        if let previous, previous.isASCII, previous.isLetter || previous.isNumber || ".-_+@".contains(previous) { return nil }
        guard var label = match(email, in: suffix) else { return nil }
        guard label.last != "-", label.last != "_" else { return nil }
        if label.lowercased().hasPrefix("xmpp:"), let path = match(resource, in: String(suffix.dropFirst(label.count))) {
            label += path
        }
        while label.last == "." { label.removeLast() }
        let prefixed = label.lowercased().hasPrefix("mailto:") || label.lowercased().hasPrefix("xmpp:")
        return (label, (prefixed ? "" : "mailto:") + label, source.index(index, offsetBy: label.count))
    }

    private static func match(_ expression: NSRegularExpression, in text: String) -> String? {
        guard let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range, in: text) else { return nil }
        return String(text[range])
    }
}
