//
//  JSONCoders.swift
//  Brief
//
//  Off-main-actor JSON coding and pure-Swift HTML entity / snippet decoding.
//

import Foundation

nonisolated enum JSONCoders {
    /// Decodes `Sendable` JSON payloads off the main actor.
    @concurrent
    static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(value)
    }
}

nonisolated enum HTMLEntityDecoder {
    private static let namedEntities: [String: Character] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "#39": "'",
        "nbsp": "\u{00A0}",
        "mdash": "\u{2014}",
        "ndash": "\u{2013}",
        "hellip": "\u{2026}",
        "lsquo": "\u{2018}",
        "rsquo": "\u{2019}",
        "ldquo": "\u{201C}",
        "rdquo": "\u{201D}",
        "bull": "\u{2022}",
        "middot": "\u{00B7}",
        "copy": "\u{00A9}",
        "reg": "\u{00AE}",
        "trade": "\u{2122}"
    ]

    /// Decodes HTML named and numeric character references in a single pass.
    static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }

        var result = String()
        result.reserveCapacity(input.count)

        var index = input.startIndex
        while index < input.endIndex {
            let char = input[index]
            guard char == "&",
                  let semicolonIndex = input[index...].firstIndex(of: ";"),
                  input.distance(from: index, to: semicolonIndex) <= 12 else {
                result.append(char)
                index = input.index(after: index)
                continue
            }

            let tokenStart = input.index(after: index)
            let token = String(input[tokenStart..<semicolonIndex])

            if let replacement = resolveEntity(token) {
                result.append(replacement)
                index = input.index(after: semicolonIndex)
            } else {
                result.append(char)
                index = input.index(after: index)
            }
        }

        return result
    }

    /// Converts Hacker News HTML fragments (comments and Ask HN bodies) into readable plain text.
    static func stripHTMLToPlainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        var normalized = html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<p>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<li[^>]*>", with: "• ", options: .regularExpression)
            .replacingOccurrences(of: "</pre>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<pre[^>]*>", with: "\n", options: .regularExpression)

        normalized = stripTags(normalized)
        let decoded = decode(normalized)
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        let lines = decoded
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var collapsed: [String] = []
        var previousWasEmpty = false
        for line in lines {
            if line.isEmpty {
                if !previousWasEmpty && !collapsed.isEmpty {
                    collapsed.append("")
                }
                previousWasEmpty = true
            } else {
                collapsed.append(line)
                previousWasEmpty = false
            }
        }

        return collapsed
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveEntity(_ token: String) -> Character? {
        if let mapped = namedEntities[token.lowercased()] {
            return mapped
        }

        guard token.hasPrefix("#") else { return nil }
        let body = token.dropFirst()

        let scalarValue: UInt32?
        if body.hasPrefix("x") || body.hasPrefix("X") {
            scalarValue = UInt32(body.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(body, radix: 10)
        }

        guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else {
            return nil
        }
        return Character(scalar)
    }

    private static func stripTags(_ input: String) -> String {
        var output = String()
        output.reserveCapacity(input.count)
        var insideTag = false

        for ch in input {
            if ch == "<" {
                insideTag = true
            } else if ch == ">" && insideTag {
                insideTag = false
            } else if !insideTag {
                output.append(ch)
            }
        }
        return output
    }
}
