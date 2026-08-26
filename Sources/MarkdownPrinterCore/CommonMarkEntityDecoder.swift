import Foundation

enum CommonMarkEntityDecoder {
    static func decode(_ source: String) -> String {
        var result = ""
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "&",
                  let decoded = decodeReference(in: source, at: index) else {
                result.append(source[index])
                index = source.index(after: index)
                continue
            }

            result.append(decoded.value)
            index = decoded.endIndex
        }

        return result
    }

    static func decodeReference(
        in source: String,
        at index: String.Index
    ) -> (value: String, endIndex: String.Index)? {
        guard source[index] == "&" else { return nil }
        let bodyStart = source.index(after: index)
        guard bodyStart < source.endIndex else { return nil }

        if source[bodyStart] == "#" {
            return decodeNumericReference(in: source, at: bodyStart)
        }

        var cursor = bodyStart
        var count = 0
        while cursor < source.endIndex,
              source[cursor].isASCII,
              source[cursor].isLetter || source[cursor].isNumber {
            count += 1
            guard count <= 32 else { return nil }
            cursor = source.index(after: cursor)
        }
        guard count > 0, cursor < source.endIndex, source[cursor] == ";" else { return nil }

        let name = String(source[bodyStart..<cursor])
        guard let value = CommonMarkNamedEntities.values[name] else { return nil }
        return (value, source.index(after: cursor))
    }

    private static func decodeNumericReference(
        in source: String,
        at hashIndex: String.Index
    ) -> (value: String, endIndex: String.Index)? {
        var cursor = source.index(after: hashIndex)
        var radix = 10
        var maximumDigits = 7
        if cursor < source.endIndex, source[cursor] == "x" || source[cursor] == "X" {
            radix = 16
            maximumDigits = 6
            cursor = source.index(after: cursor)
        }

        let digitsStart = cursor
        var count = 0
        while cursor < source.endIndex,
              count < maximumDigits,
              digitValue(source[cursor], radix: radix) != nil {
            count += 1
            cursor = source.index(after: cursor)
        }
        guard count > 0, cursor < source.endIndex, source[cursor] == ";" else { return nil }

        let digits = String(source[digitsStart..<cursor])
        guard let codePoint = UInt32(digits, radix: radix) else { return nil }
        let scalar: Unicode.Scalar
        if codePoint == 0 || codePoint > 0x10_FFFF || (0xD800...0xDFFF).contains(codePoint) {
            scalar = "\u{FFFD}"
        } else {
            scalar = Unicode.Scalar(codePoint) ?? "\u{FFFD}"
        }
        return (String(scalar), source.index(after: cursor))
    }

    private static func digitValue(_ character: Character, radix: Int) -> Int? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }
        let value: Int
        switch scalar.value {
        case 48...57: value = Int(scalar.value - 48)
        case 65...70: value = Int(scalar.value - 65 + 10)
        case 97...102: value = Int(scalar.value - 97 + 10)
        default: return nil
        }
        return value < radix ? value : nil
    }
}
