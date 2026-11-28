//
//  HTMLContentExtractor.swift
//  Brief
//
//  Pure-Swift off-main-actor HTML content extractor and self-post formatter.
//

import Foundation

nonisolated struct ExtractedArticleResult: Equatable, Sendable {
    let content: OfflineArticleContent
    let inlineImageURLs: [URL]
}

nonisolated enum HTMLContentExtractor {
    private static let noiseTags = [
        "script", "style", "noscript", "nav", "footer", "aside", "form", "svg", "template", "iframe"
    ]

    /// Extracts readable blocks, metadata, hero/inline image URLs, and a plain-text search index off the main actor.
    @concurrent
    static func extract(
        htmlData: Data,
        responseEncodingName: String?,
        sourceURL: URL,
        fallbackTitle: String,
        fallbackAuthor: String
    ) async throws -> ExtractedArticleResult {
        try Task.checkCancellation()

        guard htmlData.count <= AppConfig.maxHTMLBytes else {
            throw APIError.extractionError("Article page exceeds maximum supported size.")
        }

        let html = decodeHTMLString(from: htmlData, responseEncodingName: responseEncodingName)
        let resolvedTitle = extractTitle(from: html, fallback: fallbackTitle)
        let resolvedAuthor = extractMetaContent(in: html, keys: ["author", "article:author"]) ?? fallbackAuthor
        let heroImageURL = extractHeroImageURL(from: html, baseURL: sourceURL)

        let bodyFragment = extractPrimaryBodyHTML(from: html)
        let cleanedHTML = stripNoiseElements(from: bodyFragment)

        var collectedImageURLs: [URL] = []
        if let heroImageURL {
            collectedImageURLs.append(heroImageURL)
        }

        var blocks = parseContentBlocks(
            from: cleanedHTML,
            baseURL: sourceURL,
            heroImageURL: heroImageURL,
            collectedImageURLs: &collectedImageURLs
        )

        // Ensure hero image is preserved in metadata even if not repeated inline.
        let heroAssetID = heroImageURL.map { stableAssetID(for: $0) }
        blocks = deduplicateLeadingTitleBlock(blocks, title: resolvedTitle)

        let proseText = blocks.compactMap { block -> String? in
            switch block {
            case .heading(_, _, let text),
                 .paragraph(_, let text),
                 .blockquote(_, let text),
                 .listItem(_, _, _, let text):
                return text
            case .codeBlock(_, let text):
                return text
            case .image(_, _, _, _, let caption):
                return caption
            }
        }
        .joined(separator: "\n\n")

        let isSparse = proseText.count < AppConfig.minExtractedProseChars
        let plainTextIndex = ([resolvedTitle, resolvedAuthor, proseText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n"))
        let excerpt = buildExcerpt(from: blocks, fallback: resolvedTitle)
        let readingMinutes = estimateReadingMinutes(for: proseText)

        let content = OfflineArticleContent(
            title: resolvedTitle,
            author: resolvedAuthor,
            sourceURL: sourceURL,
            heroImageAssetID: heroAssetID,
            heroImageRemoteURL: heroImageURL,
            heroImageRelativePath: nil,
            blocks: blocks,
            plainTextIndex: plainTextIndex,
            excerpt: excerpt,
            estimatedReadingMinutes: readingMinutes,
            isSparseOrBlocked: isSparse,
            extractedAt: .now
        )

        return ExtractedArticleResult(
            content: content,
            inlineImageURLs: Array(collectedImageURLs.prefix(AppConfig.maxImagesPerArticle))
        )
    }

    /// Formats Hacker News self-post HTML (`Ask HN`, `Show HN`, text posts) into offline content blocks.
    @concurrent
    static func extractSelfPost(
        storyTextHTML: String,
        title: String,
        canonicalURL: URL,
        author: String
    ) async -> OfflineArticleContent {
        let cleaned = stripNoiseElements(from: storyTextHTML)
        var ignoredImages: [URL] = []
        let blocks = parseContentBlocks(
            from: cleaned,
            baseURL: canonicalURL,
            heroImageURL: nil,
            collectedImageURLs: &ignoredImages
        )

        let proseText = blocks.compactMap { block -> String? in
            switch block {
            case .heading(_, _, let text),
                 .paragraph(_, let text),
                 .blockquote(_, let text),
                 .codeBlock(_, let text),
                 .listItem(_, _, _, let text):
                return text
            case .image(_, _, _, _, let caption):
                return caption
            }
        }
        .joined(separator: "\n\n")

        let plainTextIndex = [title, author, proseText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return OfflineArticleContent(
            title: title,
            author: author,
            sourceURL: canonicalURL,
            heroImageAssetID: nil,
            heroImageRemoteURL: nil,
            heroImageRelativePath: nil,
            blocks: blocks,
            plainTextIndex: plainTextIndex,
            excerpt: buildExcerpt(from: blocks, fallback: title),
            estimatedReadingMinutes: estimateReadingMinutes(for: proseText),
            isSparseOrBlocked: false,
            extractedAt: .now
        )
    }

    static func stableAssetID(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "img-\(String(hash, radix: 16))"
    }

    // MARK: - Charset & Metadata

    private static func decodeHTMLString(from data: Data, responseEncodingName: String?) -> String {
        if let encoding = stringEncoding(fromCharsetName: responseEncodingName),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }

        let probeSlice = data.prefix(4096)
        if let asciiProbe = String(data: probeSlice, encoding: .ascii),
           let metaCharset = extractMetaCharset(from: asciiProbe),
           let encoding = stringEncoding(fromCharsetName: metaCharset),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stringEncoding(fromCharsetName name: String?) -> String.Encoding? {
        guard let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "iso_8859-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "us-ascii", "ascii":
            return .ascii
        case "utf-16", "utf16":
            return .utf16
        default:
            return nil
        }
    }

    private static func extractMetaCharset(from probe: String) -> String? {
        let pattern = #"(?i)charset\s*=\s*["']?([A-Za-z0-9\-_]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)),
              let range = Range(match.range(at: 1), in: probe) else {
            return nil
        }
        return String(probe[range])
    }

    private static func extractTitle(from html: String, fallback: String) -> String {
        if let ogTitle = extractMetaContent(in: html, keys: ["og:title", "twitter:title"]),
           !ogTitle.isEmpty {
            return ogTitle
        }

        if let rawTitle = firstMatchContent(pattern: #"(?is)<title\b[^>]*>(.*?)</title>"#, in: html) {
            let cleaned = normalizeInlineWhitespace(HTMLEntityDecoder.decode(stripAllTags(rawTitle)))
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return fallback
    }

    private static func extractHeroImageURL(from html: String, baseURL: URL) -> URL? {
        guard let rawImage = extractMetaContent(in: html, keys: ["og:image", "twitter:image", "twitter:image:src"]) else {
            return nil
        }
        return resolveImageURL(rawImage, baseURL: baseURL)
    }

    private static func extractMetaContent(in html: String, keys: [String]) -> String? {
        let metaPattern = #"(?is)<meta\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: metaPattern) else { return nil }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        let targetKeys = Set(keys.map { $0.lowercased() })

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            let key = (attributeValue("property", in: tag) ?? attributeValue("name", in: tag))?.lowercased()
            guard let key, targetKeys.contains(key),
                  let content = attributeValue("content", in: tag) else {
                continue
            }
            let decoded = normalizeInlineWhitespace(HTMLEntityDecoder.decode(content))
            if !decoded.isEmpty {
                return decoded
            }
        }
        return nil
    }

    // MARK: - Container Selection & Noise Stripping

    private static func extractPrimaryBodyHTML(from html: String) -> String {
        let articleCandidates = allTagInnerContents(tag: "article", in: html)
        if let richestArticle = selectRichestCandidate(from: articleCandidates),
           plainCharacterCount(in: richestArticle) >= AppConfig.minExtractedProseChars {
            return richestArticle
        }

        let mainCandidates = allTagInnerContents(tag: "main", in: html)
        if let richestMain = selectRichestCandidate(from: mainCandidates),
           plainCharacterCount(in: richestMain) >= AppConfig.minExtractedProseChars {
            return richestMain
        }

        if let bodyContent = firstMatchContent(pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#, in: html) {
            return bodyContent
        }
        return html
    }

    private static func selectRichestCandidate(from candidates: [String]) -> String? {
        candidates.max { plainCharacterCount(in: $0) < plainCharacterCount(in: $1) }
    }

    private static func plainCharacterCount(in fragment: String) -> Int {
        normalizeInlineWhitespace(stripAllTags(fragment)).count
    }

    private static func allTagInnerContents(tag: String, in html: String) -> [String] {
        let pattern = "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
    }

    private static func stripNoiseElements(from html: String) -> String {
        var result = html.replacingOccurrences(
            of: #"(?is)<!--.*?-->"#,
            with: "",
            options: .regularExpression
        )

        for tag in noiseTags {
            let pattern = "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>"
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }

    // MARK: - Block Parsing

    private static func parseContentBlocks(
        from html: String,
        baseURL: URL,
        heroImageURL: URL?,
        collectedImageURLs: inout [URL]
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var blockCounter = 0
        var listIndex = 0
        var orderedListDepth = 0
        var cursor = html.startIndex

        func nextBlockID(_ prefix: String) -> String {
            defer { blockCounter += 1 }
            return "\(prefix)-\(blockCounter)"
        }

        func appendLooseText(_ rawSegment: String) {
            let text = normalizeInlineWhitespace(HTMLEntityDecoder.decode(stripAllTags(rawSegment)))
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(id: nextBlockID("p"), text: text))
        }

        func appendImageIfValid(from imgTag: String, caption: String? = nil) {
            guard collectedImageURLs.count < AppConfig.maxImagesPerArticle else { return }
            let rawSrc = attributeValue("src", in: imgTag)
                ?? attributeValue("data-src", in: imgTag)
                ?? firstSrcsetCandidate(in: imgTag)
            guard let rawSrc, let resolvedURL = resolveImageURL(rawSrc, baseURL: baseURL) else { return }
            if isLikelyTrackingPixel(imgTag: imgTag, url: resolvedURL) { return }

            if !collectedImageURLs.contains(resolvedURL) {
                collectedImageURLs.append(resolvedURL)
            }
            let altText = caption ?? attributeValue("alt", in: imgTag)
                .map { normalizeInlineWhitespace(HTMLEntityDecoder.decode($0)) }
                .flatMap { $0.isEmpty ? nil : $0 }

            // Avoid duplicating a hero image already shown at top if first block matches.
            if blocks.isEmpty && resolvedURL == heroImageURL {
                return
            }

            blocks.append(
                .image(
                    id: nextBlockID("img"),
                    assetID: stableAssetID(for: resolvedURL),
                    remoteURL: resolvedURL,
                    relativeLocalPath: nil,
                    caption: altText
                )
            )
        }

        while cursor < html.endIndex {
            guard let tagStart = html[cursor...].firstIndex(of: "<") else {
                appendLooseText(String(html[cursor...]))
                break
            }

            if tagStart > cursor {
                let rawText = String(html[cursor..<tagStart])
                if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendLooseText(rawText)
                }
            }

            guard let tagEnd = html[tagStart...].firstIndex(of: ">") else {
                appendLooseText(String(html[tagStart...]))
                break
            }

            let rawTag = String(html[tagStart...tagEnd])
            let tagName = parseTagName(from: rawTag)
            cursor = html.index(after: tagEnd)

            switch tagName {
            case "ol":
                orderedListDepth += 1
                listIndex = 0
            case "/ol":
                orderedListDepth = max(0, orderedListDepth - 1)
                listIndex = 0
            case "ul", "/ul":
                listIndex = 0
            case "pre":
                if let (inner, nextPos) = readUntilClosingTag("pre", from: cursor, in: html) {
                    cursor = nextPos
                    let code = HTMLEntityDecoder.decode(stripAllTagsPreservingLineBreaks(inner))
                        .trimmingCharacters(in: .newlines)
                    if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(.codeBlock(id: nextBlockID("code"), text: code))
                    }
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(tagName.dropFirst()) ?? 2
                if let (inner, nextPos) = readUntilClosingTag(tagName, from: cursor, in: html) {
                    cursor = nextPos
                    let text = normalizeInlineWhitespace(HTMLEntityDecoder.decode(stripAllTags(inner)))
                    if !text.isEmpty {
                        blocks.append(.heading(id: nextBlockID("h"), level: level, text: text))
                    }
                }
            case "blockquote":
                if let (inner, nextPos) = readUntilClosingTag("blockquote", from: cursor, in: html) {
                    cursor = nextPos
                    let text = normalizeInlineWhitespace(HTMLEntityDecoder.decode(stripAllTags(inner)))
                    if !text.isEmpty {
                        blocks.append(.blockquote(id: nextBlockID("quote"), text: text))
                    }
                }
            case "li":
                if let (inner, nextPos) = readUntilClosingTag("li", from: cursor, in: html) {
                    cursor = nextPos
                    let text = normalizeInlineWhitespace(HTMLEntityDecoder.decode(stripAllTags(inner)))
                    if !text.isEmpty {
                        listIndex += 1
                        blocks.append(
                            .listItem(
                                id: nextBlockID("li"),
                                ordered: orderedListDepth > 0,
                                index: listIndex,
                                text: text
                            )
                        )
                    }
                }
            case "figure":
                if let (inner, nextPos) = readUntilClosingTag("figure", from: cursor, in: html) {
                    cursor = nextPos
                    let caption = firstMatchContent(pattern: #"(?is)<figcaption\b[^>]*>(.*?)</figcaption>"#, in: inner)
                        .map { normalizeInlineWhitespace(HTMLEntityDecoder.decode(stripAllTags($0))) }
                        .flatMap { $0.isEmpty ? nil : $0 }
                    if let imgTag = firstMatch(pattern: #"(?is)<img\b[^>]*>"#, in: inner) {
                        appendImageIfValid(from: imgTag, caption: caption)
                    }
                }
            case "p":
                if let (inner, nextPos) = readUntilClosingTag("p", from: cursor, in: html) {
                    cursor = nextPos
                    let text = normalizeInlineWhitespace(HTMLEntityDecoder.decode(stripAllTagsWithBreaks(inner)))
                    if !text.isEmpty {
                        blocks.append(.paragraph(id: nextBlockID("p"), text: text))
                    }
                    for imgTag in allMatches(pattern: #"(?is)<img\b[^>]*>"#, in: inner) {
                        appendImageIfValid(from: imgTag)
                    }
                }
            case "img":
                appendImageIfValid(from: rawTag)
            default:
                continue
            }
        }

        return blocks
    }

    private static func readUntilClosingTag(
        _ tagName: String,
        from start: String.Index,
        in html: String
    ) -> (inner: String, nextCursor: String.Index)? {
        let pattern = "(?is)</\(tagName)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(start..., in: html)),
              let closeRange = Range(match.range, in: html) else {
            return nil
        }
        return (String(html[start..<closeRange.lowerBound]), closeRange.upperBound)
    }

    private static func parseTagName(from rawTag: String) -> String {
        let trimmed = rawTag.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let token = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == ">" || ($0 == "/" && trimmed.first != "/") }).first
        return token.map { $0.lowercased() } ?? ""
    }

    private static func deduplicateLeadingTitleBlock(_ blocks: [ContentBlock], title: String) -> [ContentBlock] {
        guard let first = blocks.first else { return blocks }
        if case .heading(_, _, let text) = first,
           text.caseInsensitiveCompare(title) == .orderedSame {
            return Array(blocks.dropFirst())
        }
        return blocks
    }

    // MARK: - URL & Attribute Helpers

    private static func resolveImageURL(_ raw: String, baseURL: URL) -> URL? {
        let trimmed = HTMLEntityDecoder.decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("data:"),
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        if scheme == "http", var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            return components.url ?? resolved
        }
        return resolved
    }

    private static func firstSrcsetCandidate(in imgTag: String) -> String? {
        guard let srcset = attributeValue("srcset", in: imgTag) else { return nil }
        return srcset
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
    }

    private static func isLikelyTrackingPixel(imgTag: String, url: URL) -> Bool {
        if url.pathExtension.lowercased() == "svg" { return true }
        if let width = attributeValue("width", in: imgTag).flatMap(Int.init), width <= 2 { return true }
        if let height = attributeValue("height", in: imgTag).flatMap(Int.init), height <= 2 { return true }
        return false
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        let quotedPattern = #"(?is)\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: quotedPattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
            return nil
        }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range])
            }
        }
        return nil
    }

    // MARK: - Text Helpers

    private static func stripAllTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func stripAllTagsWithBreaks(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func stripAllTagsPreservingLineBreaks(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func normalizeInlineWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t\r\f\v]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildExcerpt(from blocks: [ContentBlock], fallback: String) -> String {
        for block in blocks {
            if case .paragraph(_, let text) = block, !text.isEmpty {
                return text.count <= 180 ? text : String(text.prefix(177)) + "..."
            }
        }
        return fallback
    }

    private static func estimateReadingMinutes(for text: String) -> Int {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return max(1, Int(ceil(Double(wordCount) / 220.0)))
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func firstMatchContent(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }
}
